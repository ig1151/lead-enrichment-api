import Joi from 'joi';
export const enrichSchema = Joi.object({
  domain: Joi.string().optional(),
  company_name: Joi.string().optional(),
  email: Joi.string().email().optional(),
  linkedin_url: Joi.string().uri().optional(),
  enrichment_type: Joi.string().valid('company', 'person', 'both').default('company'),
  include_tech_stack: Joi.boolean().default(true),
  include_buying_signals: Joi.boolean().default(true),
  generate_outreach: Joi.boolean().default(false),
  sender_name: Joi.string().optional(),
  sender_company: Joi.string().optional(),
  outreach_goal: Joi.string().optional(),
  async: Joi.boolean().default(false),
  webhook_url: Joi.string().uri({ scheme: ['https'] }).optional().when('async', { is: false, then: Joi.forbidden() }),
}).or('domain', 'company_name', 'email', 'linkedin_url').messages({
  'object.missing': 'At least one of domain, company_name, email, or linkedin_url is required',
});
export const batchSchema = Joi.object({
  leads: Joi.array().items(enrichSchema).min(1).max(10).required().messages({ 'array.max': 'Batch endpoint accepts a maximum of 10 leads per request' }),
});