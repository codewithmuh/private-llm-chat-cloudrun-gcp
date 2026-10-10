/**
 * The model presets from ml/models/catalog.json, read at BUILD time (the
 * landing page is static). Server-only: it uses the file system.
 */
import fs from "node:fs";
import path from "node:path";

export interface ModelPreset {
  id: string;
  name: string;
  description: string;
  hf_model_id: string;
  /** Cloud Run's name for the GPU: nvidia-l4 or nvidia-rtx-pro-6000. */
  gpu_type: string;
  gpu: string;
  cpu: number;
  memory: string;
  /** While awake; null = no published price yet (a preview GPU). */
  hourly_usd: number | null;
  vision: boolean;
  ocr: boolean;
  gated: boolean;
  licence: string;
  level: string;
}

// `next build` and `next dev` run in frontend/, so the repo root is "..".
// (The Dockerfile keeps the same layout: /app/frontend next to /app/ml.)
const CATALOG = path.join(process.cwd(), "..", "ml", "models", "catalog.json");

export function readModelPresets(): ModelPreset[] {
  try {
    const raw = JSON.parse(fs.readFileSync(CATALOG, "utf8")) as { presets: Record<string, Omit<ModelPreset, "id">> };
    return Object.entries(raw.presets).map(([id, preset]) => ({ id, ...preset }));
  } catch {
    // A missing catalog must not break the build; the table just says so.
    return [];
  }
}
