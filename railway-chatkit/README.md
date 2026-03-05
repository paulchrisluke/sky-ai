# Railway ChatKit Bridge

Deploy this directory as a Railway service.

## Required Railway variables

- `CLOUDFLARE_API_URL` (example: `https://sky-ai-api.paulchrisluke.workers.dev`)
- `CF_ACCESS_CLIENT_ID` and `CF_ACCESS_CLIENT_SECRET` (recommended)
- `WORKER_API_KEY` (optional fallback when API key bypass is enabled on API worker)
- `DEFAULT_ACCOUNT_ID` (optional, default `skylerbaird@me.com`)
- `DEFAULT_WORKSPACE_ID` (optional, default `default`)

## Endpoints

- `GET /health`
- `POST /chatkit`

## Example request

```bash
curl -X POST "$RAILWAY_URL/chatkit" \
  -H "content-type: application/json" \
  -d '{"query":"What emails do I have about contracts?","threadId":"test-thread-001"}'
```
