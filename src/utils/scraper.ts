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
