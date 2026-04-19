# Reading Progress Sync Worker

This Worker stores one reading-state JSON object per EPUB in Cloudflare R2. The iOS app talks to this Worker, not to R2 directly.

## What it stores

Each record includes:
- `position`
- `locatorJSON`
- `updatedAt`

The object key is `reading-state/<syncIdentifier>.json`, where `syncIdentifier` is the SHA-256 hash of the EPUB file contents.

## Endpoints

- `GET /v1/reading-state/:syncIdentifier`
- `PUT /v1/reading-state/:syncIdentifier`

Both require:

```text
Authorization: Bearer <SYNC_SECRET>
```

## Deploy

1. Install Wrangler:

```sh
npm install -g wrangler
```

2. Create the R2 bucket:

```sh
wrangler r2 bucket create reading-progress-sync
```

3. Set the shared secret:

```sh
wrangler secret put SYNC_SECRET
```

4. Deploy:

```sh
wrangler deploy
```

5. Copy the Worker URL into the app’s Settings screen on both phones.
6. Enter the same shared secret on both phones.

## Notes

- This is a single-user sync service. The shared secret is the only application-level auth.
- Last write wins based on the `updatedAt` timestamp sent by the app.
- The Worker stores reading metadata only. It does not upload EPUB files.
