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
  generate_outreach?: boolean;
  sender_name?: string;
  sender_company?: string;
  outreach_goal?: string;
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

export interface OutreachContent {
  subject?: string;
  body: string;
}
export interface PersonalizationTokens {
  company_name?: string;
  pain_point?: string;
  trigger_event?: string;
  value_prop_angle?: string;
  icebreaker?: string;
  industry_context?: string;
  company_size_context?: string;
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
  cold_email?: OutreachContent;
  linkedin_message?: string;
  follow_up_email?: OutreachContent;
  personalization_tokens?: PersonalizationTokens;
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
