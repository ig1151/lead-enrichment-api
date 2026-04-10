#!/bin/bash
set -e

echo "🚀 Building Lead Enrichment API..."

cat > src/types/index.ts << 'HEREDOC'
export type EnrichmentType = 'company' | 'person' | 'both';
export type JobStatus = 'pending' | 'processing' | 'success' | 'error';

export interface EnrichRequest {
  domain?: string;
  company_name?: string;
  email?: string;
  linkedin_url?: string;
  enrichment_type?: EnrichmentType;
  include_tech_stack?: boolean;
  include_buying_signals?: boolean;
  async?: boolean;
  webhook_url?: string;
}

export interface CompanyData {
  name?: string;
  domain?: string;
  description?: string;
  industry?: string;
  sub_industry?: string;
  employee_count?: string;
  employee_range?: string;
  founded_year?: string;
  headquarters?: string;
  company_type?: string;
  revenue_range?: string;
  funding_stage?: string;
  funding_total?: string;
  linkedin_url?: string;
  twitter_url?: string;
  facebook_url?: string;
  phone?: string;
  email_pattern?: string;
  technologies?: string[];
  keywords?: string[];
}

export interface PersonData {
  full_name?: string;
  first_name?: string;
  last_name?: string;
  title?: string;
  seniority?: string;
  department?: string;
  email?: string;
  linkedin_url?: string;
  location?: string;
  bio?: string;
}

export interface BuyingSignal {
  signal: string;
  strength: 'high' | 'medium' | 'low';
  reason: string;
}

export interface EnrichResponse {
  id: string;
  status: JobStatus;
  model: string;
  domain?: string;
  company?: CompanyData;
  person?: PersonData;
  buying_signals?: BuyingSignal[];
  lead_score?: number;
  lead_grade?: 'A' | 'B' | 'C' | 'D' | 'F';
  recommended_approach?: string;
  latency_ms: number;
  usage: { input_tokens: number; output_tokens: number };
  created_at: string;
}

export interface Job {
  job_id: string;
  status: JobStatus;
  created_at: string;
  completed_at?: string;
  result?: EnrichResponse;
  error?: string;
}

export interface BatchRequest {
  leads: EnrichRequest[];
}

export interface BatchResponse {
  batch_id: string;
  total: number;
  succeeded: number;
  failed: number;
  results: (EnrichResponse | { error: string })[];
  latency_ms: number;
}
HEREDOC

cat > src/utils/config.ts << 'HEREDOC'
import 'dotenv/config';
function required(key: string): string { const val = process.env[key]; if (!val) throw new Error(`Missing required env var: ${key}`); return val; }
function optional(key: string, fallback: string): string { return process.env[key] ?? fallback; }
export const config = {
  anthropic: { apiKey: required('ANTHROPIC_API_KEY'), model: optional('ANTHROPIC_MODEL', 'claude-sonnet-4-20250514') },
  server: { port: parseInt(optional('PORT', '3000'), 10), nodeEnv: optional('NODE_ENV', 'development'), apiVersion: optional('API_VERSION', 'v1') },
  rateLimit: { windowMs: parseInt(optional('RATE_LIMIT_WINDOW_MS', '60000'), 10), maxFree: parseInt(optional('RATE_LIMIT_MAX_FREE', '10'), 10), maxPro: parseInt(optional('RATE_LIMIT_MAX_PRO', '500'), 10) },
  jobs: { ttlSeconds: parseInt(optional('JOB_TTL_SECONDS', '3600'), 10) },
  logging: { level: optional('LOG_LEVEL', 'info') },
} as const;
HEREDOC

cat > src/utils/logger.ts << 'HEREDOC'
import pino from 'pino';
import { config } from './config';
export const logger = pino({
  level: config.logging.level,
  transport: config.server.nodeEnv === 'development' ? { target: 'pino-pretty', options: { colorize: true } } : undefined,
  base: { service: 'lead-enrichment-api' },
  timestamp: pino.stdTimeFunctions.isoTime,
  redact: { paths: ['req.headers.authorization'], censor: '[REDACTED]' },
});
HEREDOC

cat > src/utils/validation.ts << 'HEREDOC'
import Joi from 'joi';
export const enrichSchema = Joi.object({
  domain: Joi.string().optional(),
  company_name: Joi.string().optional(),
  email: Joi.string().email().optional(),
  linkedin_url: Joi.string().uri().optional(),
  enrichment_type: Joi.string().valid('company', 'person', 'both').default('company'),
  include_tech_stack: Joi.boolean().default(true),
  include_buying_signals: Joi.boolean().default(true),
  async: Joi.boolean().default(false),
  webhook_url: Joi.string().uri({ scheme: ['https'] }).optional().when('async', { is: false, then: Joi.forbidden() }),
}).or('domain', 'company_name', 'email', 'linkedin_url').messages({
  'object.missing': 'At least one of domain, company_name, email, or linkedin_url is required',
});
export const batchSchema = Joi.object({
  leads: Joi.array().items(enrichSchema).min(1).max(10).required().messages({ 'array.max': 'Batch endpoint accepts a maximum of 10 leads per request' }),
});
HEREDOC

cat > src/utils/scraper.ts << 'HEREDOC'
import axios from 'axios';
import * as cheerio from 'cheerio';
import { logger } from './logger';

export async function scrapeWebsite(domain: string): Promise<string> {
  const url = domain.startsWith('http') ? domain : `https://${domain}`;
  try {
    const response = await axios.get(url, {
      timeout: 8000,
      headers: { 'User-Agent': 'Mozilla/5.0 (compatible; LeadEnrichmentBot/1.0)' },
      maxRedirects: 3,
    });
    const $ = cheerio.load(response.data as string);
    $('script, style, nav, footer, header').remove();
    const title = $('title').text().trim();
    const metaDesc = $('meta[name="description"]').attr('content') ?? '';
    const metaKeywords = $('meta[name="keywords"]').attr('content') ?? '';
    const h1 = $('h1').first().text().trim();
    const bodyText = $('body').text().replace(/\s+/g, ' ').trim().slice(0, 3000);
    return `Title: ${title}\nMeta Description: ${metaDesc}\nKeywords: ${metaKeywords}\nH1: ${h1}\nBody: ${bodyText}`;
  } catch (err) {
    logger.warn({ domain, err }, 'Failed to scrape website — proceeding with domain only');
    return `Domain: ${domain}`;
  }
}
HEREDOC

cat > src/services/enrichment.service.ts << 'HEREDOC'
import Anthropic from '@anthropic-ai/sdk';
import { v4 as uuidv4 } from 'uuid';
import { config } from '../utils/config';
import { logger } from '../utils/logger';
import { scrapeWebsite } from '../utils/scraper';
import type { EnrichRequest, EnrichResponse } from '../types/index';

const client = new Anthropic({ apiKey: config.anthropic.apiKey });

function buildPrompt(req: EnrichRequest, websiteContent: string): string {
  const techNote = req.include_tech_stack ? '"technologies": ["<tech1>", "<tech2>"],' : '';
  const signalNote = req.include_buying_signals !== false;

  return `You are a B2B sales intelligence expert. Analyze the following information about a company and extract structured lead enrichment data.

Input:
- Domain: ${req.domain ?? 'unknown'}
- Company Name: ${req.company_name ?? 'unknown'}
- Email: ${req.email ?? 'unknown'}
- LinkedIn: ${req.linkedin_url ?? 'unknown'}

Website Content:
${websiteContent}

Return ONLY a valid JSON object — no markdown, no explanation:

{
  "company": {
    "name": "<string>",
    "domain": "<string>",
    "description": "<2-3 sentence company description>",
    "industry": "<string>",
    "sub_industry": "<string>",
    "employee_range": "<1-10|11-50|51-200|201-500|501-1000|1000+>",
    "founded_year": "<YYYY or unknown>",
    "headquarters": "<City, Country>",
    "company_type": "<B2B|B2C|B2B2C|Marketplace|SaaS|Agency|Enterprise|Startup>",
    "revenue_range": "<$0-1M|$1M-10M|$10M-50M|$50M-100M|$100M+|unknown>",
    "funding_stage": "<Bootstrapped|Pre-seed|Seed|Series A|Series B|Series C+|Public|unknown>",
    "email_pattern": "<{first}.{last}@domain.com or unknown>",
    "linkedin_url": "<string or null>",
    "twitter_url": "<string or null>",
    ${techNote}
    "keywords": ["<keyword1>", "<keyword2>", "<keyword3>"]
  },
  ${signalNote ? `"buying_signals": [
    { "signal": "<signal description>", "strength": "<high|medium|low>", "reason": "<why this is a buying signal>" }
  ],` : ''}
  "lead_score": <integer 0-100>,
  "lead_grade": "<A|B|C|D|F>",
  "recommended_approach": "<1-2 sentence outreach recommendation>"
}`;
}

export async function enrichLead(req: EnrichRequest): Promise<EnrichResponse> {
  const id = `req_${uuidv4().replace(/-/g, '').slice(0, 12)}`;
  const t0 = Date.now();

  logger.info({ id, domain: req.domain, company: req.company_name }, 'Starting lead enrichment');

  const domain = req.domain ?? extractDomainFromEmail(req.email) ?? '';
  let websiteContent = '';
  if (domain) {
    websiteContent = await scrapeWebsite(domain);
  }

  const prompt = buildPrompt({ ...req, domain }, websiteContent);

  const response = await client.messages.create({
    model: config.anthropic.model,
    max_tokens: 2048,
    messages: [{ role: 'user', content: prompt }],
  });

  const raw = response.content.find((b) => b.type === 'text')?.text ?? '{}';
  let parsed: Record<string, unknown>;
  try {
    parsed = JSON.parse(raw.replace(/```json|```/g, '').trim());
  } catch (err) {
    logger.error({ id, raw, err }, 'Failed to parse JSON');
    throw new Error('Model returned malformed JSON');
  }

  logger.info({ id, latency: Date.now() - t0 }, 'Enrichment complete');

  return {
    id,
    status: 'success',
    model: config.anthropic.model,
    domain: domain || undefined,
    company: parsed.company as EnrichResponse['company'],
    buying_signals: parsed.buying_signals as EnrichResponse['buying_signals'],
    lead_score: parsed.lead_score as number,
    lead_grade: parsed.lead_grade as EnrichResponse['lead_grade'],
    recommended_approach: parsed.recommended_approach as string,
    latency_ms: Date.now() - t0,
    usage: { input_tokens: response.usage.input_tokens, output_tokens: response.usage.output_tokens },
    created_at: new Date().toISOString(),
  };
}

function extractDomainFromEmail(email?: string): string | null {
  if (!email) return null;
  const parts = email.split('@');
  return parts.length === 2 ? parts[1] : null;
}
HEREDOC

cat > src/services/jobs.service.ts << 'HEREDOC'
import { v4 as uuidv4 } from 'uuid';
import { config } from '../utils/config';
import { logger } from '../utils/logger';
import type { Job, JobStatus, EnrichResponse } from '../types/index';
const store = new Map<string, Job>();
setInterval(() => {
  const now = Date.now(); const ttlMs = config.jobs.ttlSeconds * 1000;
  for (const [id, job] of store.entries()) { if (now - new Date(job.created_at).getTime() > ttlMs) { store.delete(id); logger.debug({ job_id: id }, 'Job expired'); } }
}, 60_000);
export function createJob(): Job { const job: Job = { job_id: `job_${uuidv4().replace(/-/g,'').slice(0,12)}`, status: 'pending', created_at: new Date().toISOString() }; store.set(job.job_id, job); return job; }
export function getJob(jobId: string): Job | undefined { return store.get(jobId); }
export function updateJob(jobId: string, status: JobStatus, result?: EnrichResponse, error?: string): void { const job = store.get(jobId); if (!job) return; job.status = status; if (result) job.result = result; if (error) job.error = error; if (status === 'success' || status === 'error') job.completed_at = new Date().toISOString(); store.set(jobId, job); }
HEREDOC

cat > src/middleware/error.middleware.ts << 'HEREDOC'
import { Request, Response, NextFunction } from 'express';
import { logger } from '../utils/logger';
export function errorHandler(err: Error, req: Request, res: Response, _next: NextFunction): void {
  logger.error({ err, path: req.path }, 'Unhandled error');
  if (err.constructor.name === 'APIError') { res.status(502).json({ error: { code: 'UPSTREAM_ERROR', message: 'Error communicating with AI provider' } }); return; }
  res.status(500).json({ error: { code: 'INTERNAL_ERROR', message: 'An unexpected error occurred' } });
}
export function notFound(req: Request, res: Response): void { res.status(404).json({ error: { code: 'NOT_FOUND', message: `Route ${req.method} ${req.path} not found` } }); }
HEREDOC

cat > src/middleware/ratelimit.middleware.ts << 'HEREDOC'
import rateLimit from 'express-rate-limit';
import { config } from '../utils/config';
export const rateLimiter = rateLimit({
  windowMs: config.rateLimit.windowMs, max: config.rateLimit.maxFree,
  standardHeaders: 'draft-7', legacyHeaders: false,
  keyGenerator: (req) => req.headers['authorization']?.replace('Bearer ', '') ?? req.ip ?? 'unknown',
  handler: (_req, res) => { res.status(429).json({ error: { code: 'RATE_LIMIT_EXCEEDED', message: 'Too many requests.' } }); },
});
HEREDOC

cat > src/routes/health.route.ts << 'HEREDOC'
import { Router, Request, Response } from 'express';
import { config } from '../utils/config';
export const healthRouter = Router();
const startTime = Date.now();
healthRouter.get('/', (_req: Request, res: Response) => {
  res.status(200).json({ status: 'ok', version: '1.0.0', model: config.anthropic.model, uptime_seconds: Math.floor((Date.now() - startTime) / 1000), timestamp: new Date().toISOString() });
});
HEREDOC

cat > src/routes/enrich.route.ts << 'HEREDOC'
import { Router, Request, Response, NextFunction } from 'express';
import { enrichSchema, batchSchema } from '../utils/validation';
import { enrichLead } from '../services/enrichment.service';
import { createJob, getJob, updateJob } from '../services/jobs.service';
import type { EnrichRequest, BatchRequest } from '../types/index';
export const enrichRouter = Router();

enrichRouter.post('/', async (req: Request, res: Response, next: NextFunction) => {
  try {
    const { error, value } = enrichSchema.validate(req.body, { abortEarly: false });
    if (error) { res.status(422).json({ error: { code: 'VALIDATION_ERROR', message: 'Validation failed', details: error.details.map((d) => d.message) } }); return; }
    if (value.async) {
      const job = createJob();
      res.status(202).json({ job_id: job.job_id, status: 'pending' });
      setImmediate(async () => {
        updateJob(job.job_id, 'processing');
        try { const result = await enrichLead(value); updateJob(job.job_id, 'success', result); }
        catch (err) { updateJob(job.job_id, 'error', undefined, err instanceof Error ? err.message : 'Unknown'); }
      });
      return;
    }
    res.status(200).json(await enrichLead(value));
  } catch (err) { next(err); }
});

enrichRouter.post('/batch', async (req: Request, res: Response, next: NextFunction) => {
  try {
    const { error, value } = batchSchema.validate(req.body, { abortEarly: false });
    if (error) { res.status(422).json({ error: { code: 'VALIDATION_ERROR', message: 'Validation failed', details: error.details.map((d) => d.message) } }); return; }
    const t0 = Date.now();
    const results = await Promise.allSettled((value as BatchRequest).leads.map((lead: EnrichRequest) => enrichLead(lead)));
    const out = results.map((r) => r.status === 'fulfilled' ? r.value : { error: r.reason instanceof Error ? r.reason.message : 'Unknown' });
    res.status(200).json({ batch_id: `batch_${Date.now()}`, total: (value as BatchRequest).leads.length, succeeded: out.filter((r) => !('error' in r)).length, failed: out.filter((r) => 'error' in r).length, results: out, latency_ms: Date.now() - t0 });
  } catch (err) { next(err); }
});

enrichRouter.get('/jobs/:jobId', (req: Request, res: Response) => {
  const job = getJob(req.params.jobId);
  if (!job) { res.status(404).json({ error: { code: 'JOB_NOT_FOUND', message: `No job found: ${req.params.jobId}` } }); return; }
  res.status(200).json(job);
});
HEREDOC

cat > src/routes/openapi.route.ts << 'HEREDOC'
import { Router, Request, Response } from 'express';
import { config } from '../utils/config';
export const openapiRouter = Router();
openapiRouter.get('/', (_req: Request, res: Response) => {
  res.status(200).json({
    openapi: '3.0.3',
    info: { title: 'Lead Enrichment API', version: '1.0.0', description: 'Enrich leads with company data, firmographics, tech stack and buying signals — powered by Claude AI.' },
    servers: [{ url: 'https://lead-enrichment-api.onrender.com', description: 'Production' }, { url: `http://localhost:${config.server.port}`, description: 'Local' }],
    paths: {
      '/v1/health': { get: { summary: 'Health check', operationId: 'getHealth', responses: { '200': { description: 'Service is healthy' } } } },
      '/v1/enrich': {
        post: {
          summary: 'Enrich a single lead',
          operationId: 'enrichLead',
          requestBody: { required: true, content: { 'application/json': { schema: { $ref: '#/components/schemas/EnrichRequest' }, examples: { domain: { summary: 'Enrich by domain', value: { domain: 'stripe.com', include_tech_stack: true, include_buying_signals: true } }, email: { summary: 'Enrich by email', value: { email: 'john@stripe.com', enrichment_type: 'both' } } } } } },
          responses: { '200': { description: 'Enriched lead data' }, '202': { description: 'Async job accepted' }, '422': { description: 'Validation error' }, '429': { description: 'Rate limit exceeded' }, '500': { description: 'Internal error' } },
        },
      },
      '/v1/enrich/batch': { post: { summary: 'Enrich up to 10 leads at once', operationId: 'enrichBatch', requestBody: { required: true, content: { 'application/json': { schema: { $ref: '#/components/schemas/BatchRequest' } } } }, responses: { '200': { description: 'Batch results' }, '422': { description: 'Validation error' } } } },
      '/v1/enrich/jobs/{job_id}': { get: { summary: 'Poll async job', operationId: 'getJob', parameters: [{ name: 'job_id', in: 'path', required: true, schema: { type: 'string' } }], responses: { '200': { description: 'Job status' }, '404': { description: 'Not found' } } } },
    },
    components: {
      schemas: {
        EnrichRequest: { type: 'object', properties: { domain: { type: 'string', example: 'stripe.com' }, company_name: { type: 'string', example: 'Stripe' }, email: { type: 'string', format: 'email', example: 'john@stripe.com' }, linkedin_url: { type: 'string', format: 'uri' }, enrichment_type: { type: 'string', enum: ['company', 'person', 'both'], default: 'company' }, include_tech_stack: { type: 'boolean', default: true }, include_buying_signals: { type: 'boolean', default: true }, async: { type: 'boolean', default: false }, webhook_url: { type: 'string', format: 'uri' } } },
        EnrichResponse: { type: 'object', properties: { id: { type: 'string' }, status: { type: 'string' }, model: { type: 'string' }, domain: { type: 'string' }, company: { type: 'object' }, buying_signals: { type: 'array', items: { type: 'object', properties: { signal: { type: 'string' }, strength: { type: 'string', enum: ['high', 'medium', 'low'] }, reason: { type: 'string' } } } }, lead_score: { type: 'integer', minimum: 0, maximum: 100 }, lead_grade: { type: 'string', enum: ['A', 'B', 'C', 'D', 'F'] }, recommended_approach: { type: 'string' }, latency_ms: { type: 'integer' }, usage: { type: 'object', properties: { input_tokens: { type: 'integer' }, output_tokens: { type: 'integer' } } }, created_at: { type: 'string', format: 'date-time' } } },
        BatchRequest: { type: 'object', required: ['leads'], properties: { leads: { type: 'array', items: { $ref: '#/components/schemas/EnrichRequest' }, minItems: 1, maxItems: 10 } } },
        Job: { type: 'object', properties: { job_id: { type: 'string' }, status: { type: 'string', enum: ['pending', 'processing', 'success', 'error'] }, created_at: { type: 'string', format: 'date-time' }, completed_at: { type: 'string', format: 'date-time' }, result: { $ref: '#/components/schemas/EnrichResponse' }, error: { type: 'string' } } },
      },
    },
  });
});
HEREDOC

cat > src/app.ts << 'HEREDOC'
import express from 'express';
import cors from 'cors';
import helmet from 'helmet';
import compression from 'compression';
import pinoHttp from 'pino-http';
import { enrichRouter } from './routes/enrich.route';
import { healthRouter } from './routes/health.route';
import { openapiRouter } from './routes/openapi.route';
import { errorHandler, notFound } from './middleware/error.middleware';
import { rateLimiter } from './middleware/ratelimit.middleware';
import { logger } from './utils/logger';
import { config } from './utils/config';
const app = express();
app.use(helmet()); app.use(cors()); app.use(compression());
app.use(pinoHttp({ logger }));
app.use(express.json({ limit: '10mb' }));
app.use(express.urlencoded({ extended: true, limit: '10mb' }));
app.use(`/${config.server.apiVersion}/enrich`, rateLimiter);
app.use(`/${config.server.apiVersion}/enrich`, enrichRouter);
app.use(`/${config.server.apiVersion}/health`, healthRouter);
app.use('/openapi.json', openapiRouter);
app.get('/', (_req, res) => res.redirect(`/${config.server.apiVersion}/health`));
app.use(notFound); app.use(errorHandler);
export { app };
HEREDOC

cat > src/index.ts << 'HEREDOC'
import { app } from './app';
import { config } from './utils/config';
import { logger } from './utils/logger';
const server = app.listen(config.server.port, () => { logger.info({ port: config.server.port, env: config.server.nodeEnv }, '🚀 Lead Enrichment API started'); });
const shutdown = (signal: string) => { logger.info({ signal }, 'Shutting down'); server.close(() => { logger.info('Closed'); process.exit(0); }); setTimeout(() => process.exit(1), 10_000); };
process.on('SIGTERM', () => shutdown('SIGTERM'));
process.on('SIGINT', () => shutdown('SIGINT'));
process.on('unhandledRejection', (reason) => logger.error({ reason }, 'Unhandled rejection'));
process.on('uncaughtException', (err) => { logger.fatal({ err }, 'Uncaught exception'); process.exit(1); });
HEREDOC

cat > jest.config.js << 'HEREDOC'
module.exports = { preset: 'ts-jest', testEnvironment: 'node', rootDir: '.', testMatch: ['**/tests/**/*.test.ts'], collectCoverageFrom: ['src/**/*.ts', '!src/index.ts'], setupFiles: ['<rootDir>/tests/setup.ts'] };
HEREDOC

cat > tests/setup.ts << 'HEREDOC'
process.env.ANTHROPIC_API_KEY = 'sk-ant-test-key';
process.env.NODE_ENV = 'test';
process.env.LOG_LEVEL = 'silent';
HEREDOC

cat > .gitignore << 'HEREDOC'
node_modules/
dist/
.env
coverage/
*.log
.DS_Store
HEREDOC

cat > render.yaml << 'HEREDOC'
services:
  - type: web
    name: lead-enrichment-api
    runtime: node
    buildCommand: npm install && npm run build
    startCommand: node dist/index.js
    healthCheckPath: /v1/health
    envVars:
      - key: NODE_ENV
        value: production
      - key: LOG_LEVEL
        value: info
      - key: ANTHROPIC_API_KEY
        sync: false
HEREDOC

echo ""
echo "✅ All files created! Run: npm install"