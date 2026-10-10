import Link from "next/link";
import { ArrowRight, KeyRound, Lock, Power, Route } from "lucide-react";
import styles from "./Architecture.module.css";
import landing from "./landing.module.css";

/* One box of the diagram: a rounded rectangle with a title, a subtitle and an optional accent note. */
function Box({
  x,
  y,
  w,
  h = 76,
  title,
  sub,
  note,
  accent,
}: {
  x: number;
  y: number;
  w: number;
  h?: number;
  title: string;
  sub: string;
  note?: string;
  accent?: boolean;
}) {
  const cx = x + w / 2;
  const top = note ? y + h / 2 - 14 : y + h / 2 - 4;
  return (
    <g>
      <rect x={x} y={y} width={w} height={h} rx={12} className={accent ? styles.boxAccent : styles.box} />
      <text x={cx} y={top} textAnchor="middle" className={styles.title}>
        {title}
      </text>
      <text x={cx} y={top + 21} textAnchor="middle" className={styles.sub}>
        {sub}
      </text>
      {note && (
        <text x={cx} y={top + 41} textAnchor="middle" className={styles.edgeLabelAccent}>
          {note}
        </text>
      )}
    </g>
  );
}

/** Wide screens: the whole Google Cloud stack as an SVG, colored by the theme tokens. */
function DiagramSvg() {
  return (
    <svg
      viewBox="0 0 1120 500"
      className={styles.svg}
      role="img"
      aria-labelledby="arch-title arch-desc"
    >
      <title id="arch-title">Architecture on Google Cloud</title>
      <desc id="arch-desc">
        The browser reaches the web service (Next.js on Cloud Run) over HTTPS. It serves the UI and forwards /api/*
        to the api service (Django), with a Google ID token: the api is private, and the browser only ever sees one
        origin. The api runs in one instance with two sidecar containers, SearXNG for web search and whisper.cpp for
        voice input. It stores data in Cloud SQL for PostgreSQL, files in a private Cloud Storage bucket, reads its
        secrets from Secret Manager, and streams answers from a private model service (vLLM on a Cloud Run GPU), also
        with a Google ID token. The model service has no instance while nobody chats, and reads the model weights from
        a Cloud Storage bucket mounted read-only.
      </desc>
      <defs>
        <marker id="arch-arrow" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" orient="auto">
          <path d="M0 0 L10 5 L0 10 z" className={styles.arrowHead} />
        </marker>
        <marker id="arch-arrow-accent" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" orient="auto">
          <path d="M0 0 L10 5 L0 10 z" className={styles.arrowHeadAccent} />
        </marker>
      </defs>

      {/* Your Google Cloud project */}
      <rect x={240} y={8} width={862} height={476} rx={18} className={styles.boundary} />
      <text x={258} y={30} className={styles.groupLabel}>
        Your Google Cloud project
      </text>

      {/* Cloud Run */}
      <rect x={262} y={44} width={818} height={272} rx={16} className={styles.group} />
      <text x={1062} y={67} textAnchor="end" className={styles.groupLabel}>
        Cloud Run · scales to zero when idle
      </text>

      {/* the api and its two sidecars share one instance */}
      <rect x={518} y={70} width={270} height={230} rx={14} className={styles.boundary} />
      <text x={532} y={289} className={styles.groupLabel}>
        one instance
      </text>

      {/* edges (drawn first so boxes sit on top) */}
      <path d="M190 122 H276" className={styles.edge} markerEnd="url(#arch-arrow)" />
      <text x={214} y={112} textAnchor="middle" className={styles.edgeLabel}>
        HTTPS
      </text>
      <path d="M442 122 H526" className={styles.edge} markerEnd="url(#arch-arrow)" />
      <text x={484} y={112} textAnchor="middle" className={styles.edgeLabel}>
        /api/*
      </text>
      <text x={484} y={142} textAnchor="middle" className={styles.edgeLabel}>
        ID token
      </text>

      <path d="M590 160 V190" className={styles.edge} markerEnd="url(#arch-arrow)" />
      <path d="M716 160 V190" className={styles.edge} markerEnd="url(#arch-arrow)" />

      <path d="M600 300 V340 H352 V374" className={styles.edge} markerEnd="url(#arch-arrow)" />
      <path d="M552 340 V374" className={styles.edge} markerEnd="url(#arch-arrow)" />
      <path d="M600 340 H742 V374" className={styles.edge} markerEnd="url(#arch-arrow)" />
      <text x={372} y={333} className={styles.edgeLabel}>
        SQL · files · secrets
      </text>

      <path d="M774 122 H856" className={styles.edgeAccent} markerEnd="url(#arch-arrow-accent)" />
      <text x={825} y={112} textAnchor="middle" className={styles.edgeLabelAccent}>
        ID token
      </text>
      <text x={825} y={142} textAnchor="middle" className={styles.edgeLabelAccent}>
        streaming
      </text>
      <path d="M962 380 V194" className={styles.edge} markerEnd="url(#arch-arrow)" />
      <text x={950} y={258} textAnchor="end" className={styles.edgeLabel}>
        mounted read-only
      </text>

      {/* boxes */}
      <Box x={20} y={84} w={170} title="Browser" sub="your team" />
      <Box x={282} y={84} w={160} title="web" sub="Next.js · one origin" />
      <Box x={532} y={84} w={242} title="api" sub="Django, SSE · private" />
      <Box x={532} y={196} w={116} h={72} title="SearXNG" sub="web search" />
      <Box x={658} y={196} w={116} h={72} title="whisper.cpp" sub="voice input" />
      <Box
        x={862}
        y={84}
        w={200}
        h={104}
        title="model service"
        sub="vLLM on an NVIDIA L4"
        note="0 instances while idle"
        accent
      />

      <Box x={262} y={380} w={180} title="Cloud SQL" sub="PostgreSQL" />
      <Box x={462} y={380} w={180} title="Cloud Storage" sub="private files" />
      <Box x={662} y={380} w={160} title="Secret Manager" sub="keys, passwords" />
      <Box x={862} y={380} w={200} title="Cloud Storage" sub="model weights" />
    </svg>
  );
}

/** Phones: the same picture as a vertical flow. */
function DiagramStack() {
  return (
    <ol className={styles.stack} aria-label="Architecture on Google Cloud, top to bottom">
      <li className={styles.node}>
        <strong>Browser</strong>
        <span>your team</span>
      </li>
      <li className={styles.link}>HTTPS</li>
      <li className={styles.node}>
        <strong>web (Cloud Run)</strong>
        <span>Next.js: the UI, and one origin for the app and the API</span>
      </li>
      <li className={styles.link}>/api/* with a Google ID token</li>
      <li className={styles.stackGroup}>
        <span className={styles.stackGroupLabel}>api (Cloud Run), one instance</span>
        <div className={styles.stackRow}>
          <div className={styles.node}>
            <strong>api</strong>
            <span>Django, SSE</span>
          </div>
          <div className={styles.node}>
            <strong>SearXNG</strong>
            <span>web search</span>
          </div>
          <div className={styles.node}>
            <strong>whisper.cpp</strong>
            <span>voice input</span>
          </div>
        </div>
      </li>
      <li className={styles.link}>api: SQL · files · secrets</li>
      <li className={styles.stackRow}>
        <div className={styles.node}>
          <strong>Cloud SQL</strong>
          <span>PostgreSQL</span>
        </div>
        <div className={styles.node}>
          <strong>Cloud Storage</strong>
          <span>private files</span>
        </div>
        <div className={styles.node}>
          <strong>Secret Manager</strong>
          <span>keys, passwords</span>
        </div>
      </li>
      <li className={`${styles.link} ${styles.linkAccent}`}>api: Google ID token, streaming</li>
      <li className={`${styles.node} ${styles.nodeAccent}`}>
        <strong>model service (Cloud Run GPU)</strong>
        <span>vLLM on an NVIDIA L4 · 0 instances while idle</span>
      </li>
      <li className={styles.link}>weights, mounted read-only</li>
      <li className={styles.node}>
        <strong>Cloud Storage</strong>
        <span>model weights</span>
      </li>
    </ol>
  );
}

const DECISIONS = [
  {
    icon: KeyRound,
    title: "A private model",
    text: "Cloud Run only lets a request reach the model service with a Google ID token for the api's service account. There is no API key to leak.",
  },
  {
    icon: Power,
    title: "Cloud Run owns the GPU",
    text: "No controller to run: Cloud Run starts an instance when a message arrives and removes it about 15 idle minutes later. Set min_instances = 1 to keep it warm.",
  },
  {
    icon: Route,
    title: "One origin",
    text: "The web service serves the UI and forwards /api/* to the private api, so HttpOnly session cookies and CSRF protection need no cross-site setup.",
  },
  {
    icon: Lock,
    title: "Your data stays put",
    text: "Prompts are never logged, files live in a private bucket behind 5-minute signed URLs, and the weights are copied once into your own bucket.",
  },
];

export function Architecture() {
  return (
    <section id="architecture" className={landing.section}>
      <div className={landing.container}>
        <div className={landing.sectionHead}>
          <span className={landing.eyebrow}>Architecture</span>
          <h2 className={landing.h2}>A standard Google Cloud stack you can read in one sitting</h2>
          <p className={landing.lead}>
            Everything runs in your Google Cloud project, created by Terraform. Locally, Docker Compose runs the same web
            and api images with PostgreSQL, Mailpit, SearXNG for web search, and an open-source model on your own GPU.
          </p>
        </div>

        <figure className={styles.figure}>
          <DiagramSvg />
          <DiagramStack />
          <figcaption className={styles.caption}>
            One request path for everything; the GPU is the only expensive part, and Cloud Run only runs it while
            someone is chatting.
          </figcaption>
        </figure>

        <ul className={styles.decisions}>
          {DECISIONS.map(({ icon: Icon, title, text }) => (
            <li key={title} className={styles.decision}>
              <Icon size={18} aria-hidden className={styles.decisionIcon} />
              <div>
                <strong>{title}.</strong> {text}
              </div>
            </li>
          ))}
        </ul>

        <Link href="/docs/architecture" className={landing.moreLink}>
          Read the architecture docs <ArrowRight size={16} aria-hidden />
        </Link>
      </div>
    </section>
  );
}
