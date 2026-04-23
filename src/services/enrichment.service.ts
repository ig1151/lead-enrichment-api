import { v4 as uuidv4 } from 'uuid';
import { logger } from '../utils/logger';
import { scrapeWebsite } from '../utils/scraper';
import type { EnrichRequest, EnrichResponse } from '../types/index';

const OPENROUTER_API_URL = 'https://openrouter.ai/api/v1/chat/completions';
const MODEL = 'anthropic/claude-sonnet-4-5';

function buildPrompt(req: EnrichRequest, websiteContent: string): string {
  const techNote = req.include_tech_stack ? '"technologies": ["<tech1>", "<tech2>"],' : '';
  const signalNote = req.include_buying_signals !== false;
  const outreachNote = req.generate_outreach === true;

  const outreachBlock = outreachNote ? `,
  "cold_email": {
    "subject": "<compelling subject line>",
    "body": "<personalised cold email 3-4 short paragraphs, signed by ${req.sender_name ?? 'the sender'} from ${req.sender_company ?? 'their company'}>"
  },
  "linkedin_message": "<personalised LinkedIn connection request under 300 characters>",
  "follow_up_email": {
    "subject": "<follow up subject line>",
    "body": "<short follow up email assuming no response after 5 days>"
  }` : '';

  const personalizationBlock = `,
  "personalization_tokens": {
    "company_name": "<company name>",
    "pain_point": "<main pain point or challenge this company faces>",
    "trigger_event": "<recent event, milestone or news that makes this a good time to reach out>",
    "value_prop_angle": "<best angle to position your solution for this company>",
    "icebreaker": "<one sentence conversation starter based on something specific about this company>",
    "industry_context": "<relevant industry trend or challenge affecting this company>",
    "company_size_context": "<context about their size that affects how you'd approach them>"
  }`;

  const goalNote = req.outreach_goal ? `Outreach goal: ${req.outreach_goal}.` : '';
  const senderNote = req.sender_name ? `Sender: ${req.sender_name} from ${req.sender_company ?? 'their company'}.` : '';

  return `You are a B2B sales intelligence expert. Analyze the following information about a company and extract structured lead enrichment data.
${goalNote}
${senderNote}

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
  ${personalizationBlock}
  ${outreachBlock}
}`;
}

export async function enrichLead(req: EnrichRequest): Promise<EnrichResponse> {
  const id = `req_${uuidv4().replace(/-/g, '').slice(0, 12)}`;
  const t0 = Date.now();
  const apiKey = process.env.OPENROUTER_API_KEY;
  if (!apiKey) throw new Error('OPENROUTER_API_KEY not set');

  logger.info({ id, domain: req.domain, company: req.company_name }, 'Starting lead enrichment');

  const domain = req.domain ?? extractDomainFromEmail(req.email) ?? '';
  let websiteContent = '';
  if (domain) websiteContent = await scrapeWebsite(domain);

  const prompt = buildPrompt({ ...req, domain }, websiteContent);

  const response = await fetch(OPENROUTER_API_URL, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'Authorization': `Bearer ${apiKey}`,
    },
    body: JSON.stringify({
      model: MODEL,
      max_tokens: 2048,
      messages: [{ role: 'user', content: prompt }],
      response_format: { type: 'json_object' },
    }),
  });

  if (!response.ok) {
    const err = await response.text();
    throw new Error(`OpenRouter error: ${response.status} ${err}`);
  }

  const data = await response.json() as { choices: { message: { content: string } }[], usage: { prompt_tokens: number; completion_tokens: number } };
  const raw = data.choices[0].message.content ?? '{}';

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
    model: MODEL,
    domain: domain || undefined,
    company: parsed.company as EnrichResponse['company'],
    buying_signals: parsed.buying_signals as EnrichResponse['buying_signals'],
    lead_score: parsed.lead_score as number,
    lead_grade: parsed.lead_grade as EnrichResponse['lead_grade'],
    recommended_approach: parsed.recommended_approach as string,
    personalization_tokens: parsed.personalization_tokens as EnrichResponse['personalization_tokens'],
    cold_email: parsed.cold_email as EnrichResponse['cold_email'],
    linkedin_message: parsed.linkedin_message as string | undefined,
    follow_up_email: parsed.follow_up_email as EnrichResponse['follow_up_email'],
    latency_ms: Date.now() - t0,
    usage: { input_tokens: data.usage.prompt_tokens, output_tokens: data.usage.completion_tokens },
    created_at: new Date().toISOString(),
  };
}

function extractDomainFromEmail(email?: string): string | null {
  if (!email) return null;
  const parts = email.split('@');
  return parts.length === 2 ? parts[1] : null;
}
