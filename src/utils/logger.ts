import pino from 'pino';
import { config } from './config';
export const logger = pino({
  level: config.logging.level,
  transport: config.server.nodeEnv === 'development' ? { target: 'pino-pretty', options: { colorize: true } } : undefined,
  base: { service: 'lead-enrichment-api' },
  timestamp: pino.stdTimeFunctions.isoTime,
  redact: { paths: ['req.headers.authorization'], censor: '[REDACTED]' },
});
