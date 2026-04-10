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
