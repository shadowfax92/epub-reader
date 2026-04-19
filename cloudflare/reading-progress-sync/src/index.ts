interface ReadingPosition {
  chapterIndex: number;
  paragraphIndex: number;
  globalWordIndex: number;
}

interface ReadingStateRecord {
  position?: ReadingPosition;
  locatorJSON?: string;
  updatedAt: number;
}

interface Env {
  READING_PROGRESS: R2Bucket;
  SYNC_SECRET: string;
}

const corsHeaders = {
  "access-control-allow-origin": "*",
  "access-control-allow-headers": "authorization, content-type",
  "access-control-allow-methods": "GET, PUT, OPTIONS",
};

const jsonHeaders = {
  ...corsHeaders,
  "content-type": "application/json; charset=utf-8",
};

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: jsonHeaders });
}

function objectKey(request: Request): string | null {
  const url = new URL(request.url);
  const prefix = "/v1/reading-state/";

  if (!url.pathname.startsWith(prefix)) {
    return null;
  }

  const syncIdentifier = decodeURIComponent(url.pathname.slice(prefix.length)).trim();
  if (syncIdentifier.length == 0 || syncIdentifier.length > 160) {
    return null;
  }

  return `reading-state/${syncIdentifier}.json`;
}

function isAuthorized(request: Request, env: Env): boolean {
  return request.headers.get("authorization") === `Bearer ${env.SYNC_SECRET}`;
}

function isReadingPosition(value: unknown): value is ReadingPosition {
  if (typeof value !== "object" || value === null) {
    return false;
  }

  const position = value as Record<string, unknown>;

  return typeof position.chapterIndex === "number"
    && typeof position.paragraphIndex === "number"
    && typeof position.globalWordIndex === "number";
}

function isReadingStateRecord(value: unknown): value is ReadingStateRecord {
  if (typeof value !== "object" || value === null) {
    return false;
  }

  const record = value as Record<string, unknown>;
  const position = record.position;
  const locatorJSON = record.locatorJSON;

  return typeof record.updatedAt === "number"
    && (position === undefined || isReadingPosition(position))
    && (locatorJSON === undefined || typeof locatorJSON === "string");
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    if (request.method === "OPTIONS") {
      return new Response(null, { status: 204, headers: corsHeaders });
    }

    const key = objectKey(request);
    if (key === null) {
      return json({ error: "Not found" }, 404);
    }

    if (!isAuthorized(request, env)) {
      return json({ error: "Unauthorized" }, 401);
    }

    if (request.method === "GET") {
      const object = await env.READING_PROGRESS.get(key);
      if (object === null) {
        return json({ error: "Not found" }, 404);
      }

      return new Response(await object.text(), {
        status: 200,
        headers: jsonHeaders,
      });
    }

    if (request.method !== "PUT") {
      return new Response("Method Not Allowed", {
        status: 405,
        headers: {
          ...corsHeaders,
          allow: "GET, PUT, OPTIONS",
        },
      });
    }

    let incoming: unknown;

    try {
      incoming = await request.json();
    } catch {
      return json({ error: "Invalid JSON" }, 400);
    }

    if (!isReadingStateRecord(incoming)) {
      return json({ error: "Invalid reading state payload" }, 400);
    }

    let nextRecord = incoming;
    const existingObject = await env.READING_PROGRESS.get(key);

    if (existingObject !== null) {
      try {
        const existing = JSON.parse(await existingObject.text());
        if (isReadingStateRecord(existing) && existing.updatedAt > incoming.updatedAt) {
          nextRecord = existing;
        }
      } catch {
      }
    }

    await env.READING_PROGRESS.put(key, JSON.stringify(nextRecord), {
      httpMetadata: {
        contentType: "application/json",
      },
    });

    return json(nextRecord);
  },
} satisfies ExportedHandler<Env>;
