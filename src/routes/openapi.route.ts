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
