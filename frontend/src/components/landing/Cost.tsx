import Link from "next/link";
import { ArrowRight, PiggyBank } from "lucide-react";
import styles from "./landing.module.css";

// Estimates, us-central1, October 2026. The default preset (Qwen3-VL 8B) runs on one NVIDIA L4 with
// 8 vCPU / 32 GiB: GPU + CPU + memory while an instance is awake, $0 while it sleeps. A month is 730 hours.
const RATE = 1.42;
const ALWAYS_ON = Math.round(RATE * 730); // ≈ $1,037
const TWO_HOURS_A_DAY = Math.round(RATE * 2 * 22); // 2 h on 22 days ≈ $62

const BASELINE = [
  ["Cloud SQL for PostgreSQL (smallest tier)", "$9–10"],
  ["Cloud Run: web and api (scale to zero)", "pennies"],
  ["Artifact Registry (cached vLLM image)", "≈ $1"],
  ["Cloud Storage (an 8B model ≈ 10 GB)", "≈ $0.20"],
  ["Secrets, logs, the rest", "$1–3"],
];

const usd = (n: number) => `$${n.toLocaleString("en-US")}`;

export function Cost() {
  return (
    <section id="cost" className={`${styles.section} ${styles.sectionAlt}`}>
      <div className={styles.container}>
        <div className={styles.sectionHead}>
          <span className={styles.eyebrow}>Cost</span>
          <h2 className={styles.h2}>Pay for the GPU only while someone is using it</h2>
          <p className={styles.lead}>
            A small baseline for the app, plus GPU hours while a model is awake: about $1.05–$1.42 per hour on an
            NVIDIA L4, and $0 while it sleeps. Estimates for us-central1, October 2026.
          </p>
        </div>

        <div className={styles.costGrid}>
          <div className={styles.costCard}>
            <div className={styles.costLabel}>The app on Google Cloud, mostly idle</div>
            <div className={styles.costBig}>
              ≈ $12–15 <small>/ month</small>
            </div>
            <ul className={styles.costList}>
              {BASELINE.map(([item, price]) => (
                <li key={item}>
                  <span>{item}</span>
                  <span>{price}</span>
                </li>
              ))}
            </ul>
          </div>

          <div className={styles.costCard}>
            <div className={styles.costLabel}>
              One GPU: NVIDIA L4 (24 GB) with 8 vCPU / 32 GiB at ${RATE}/hour while awake
            </div>
            <div className={styles.bars}>
              <div className={styles.barRow}>
                <div className={styles.barLabel}>
                  <span>
                    <code>min_instances = 1</code>, 24/7
                  </span>
                  <strong>≈ {usd(ALWAYS_ON)}/month</strong>
                </div>
                <div className={styles.barTrack}>
                  <div className={styles.barFill} style={{ width: "100%" }} />
                </div>
              </div>
              <div className={styles.barRow}>
                <div className={styles.barLabel}>
                  <span>
                    Scale to zero, 2 h of chat a day on 22 days
                  </span>
                  <strong>≈ {usd(TWO_HOURS_A_DAY)}/month</strong>
                </div>
                <div className={styles.barTrack}>
                  <div
                    className={`${styles.barFill} ${styles.barFillAccent}`}
                    style={{ width: `${(TWO_HOURS_A_DAY / ALWAYS_ON) * 100}%` }}
                  />
                </div>
                <span className={styles.barNote}>
                  Woken by the first message (about 1–3 min), asleep again about 15 idle minutes later. Each wake
                  costs roughly $0.35–0.50.
                </span>
              </div>
            </div>
            <div className={styles.saving}>
              <PiggyBank size={18} aria-hidden />
              <span>
                A forgotten GPU is the classic surprise bill. With scale to zero (the default) it can&apos;t happen
                by accident: no instance, no GPU bill.
              </span>
            </div>
          </div>
        </div>

        <Link href="/docs/cost" className={styles.moreLink}>
          The full cost breakdown <ArrowRight size={16} aria-hidden />
        </Link>
      </div>
    </section>
  );
}
