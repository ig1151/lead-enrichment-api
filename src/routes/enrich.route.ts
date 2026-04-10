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
