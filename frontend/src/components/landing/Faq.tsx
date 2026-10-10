import type { ReactNode } from "react";
import Link from "next/link";
import { ChevronDown } from "lucide-react";
import { repoFileUrl } from "@/lib/site";
import styles from "./landing.module.css";

const QUESTIONS: { q: string; a: ReactNode }[] = [
  {
    q: "Do I need a GPU on my laptop?",
    a: (
      <>
        No. The laptop setup runs on any machine (it is faster with a GPU or Apple Silicon). The cloud GPU lives on
        Cloud Run.
      </>
    ),
  },
  {
    q: "Why Cloud Run and not a plain GPU VM?",
    a: (
      <>
        It scales to zero by itself: no instance and no GPU bill while nobody chats, and no controller for you to
        run. Only your api can call the model (Google ID tokens, no API key), and a project&apos;s first GPU deploy in
        a region gets 3 NVIDIA L4 GPUs of quota automatically. The serving container is vLLM&apos;s official image, so
        moving to a VM, GKE or on-prem later is easy: the app only needs an OpenAI-compatible URL.
      </>
    ),
  },
  {
    q: "What happens when the GPU is asleep?",
    a: (
      <>
        Your next message wakes it: the chat shows &ldquo;Waking up the GPU…&rdquo; for about 1–3 minutes while
        Cloud Run starts an instance and vLLM loads the weights from your Cloud Storage bucket. After about 15 idle
        minutes it goes back to sleep. To keep a model always warm, set <code>min_instances = 1</code> in Terraform
        (billed 24/7).
      </>
    ),
  },
  {
    q: "How much does it cost?",
    a: (
      <>
        Estimates for us-central1: the app itself is about $12–15/month when mostly idle (a small Cloud SQL
        database, plus Cloud Run, Cloud Storage and Artifact Registry, which cost little while idle). The GPU is
        billed only while a model is awake: about $1.05–1.42/hour on an L4, and $0 while it sleeps. 2 hours of chat a
        day on 22 days is about $62. See the <Link href="/docs/cost">cost guide</Link>.
      </>
    ),
  },
  {
    q: "Is it production ready?",
    a: (
      <>
        It&apos;s a solid, secure base: auth with 2FA, private services that only accept Google ID tokens, encrypted
        storage, tests and CI. Before putting company data in it, review the settings for your needs (backups, your
        email provider, a WAF, monitoring):{" "}
        <a href={repoFileUrl("SECURITY.md")} target="_blank" rel="noopener noreferrer">
          SECURITY.md
        </a>
        .
      </>
    ),
  },
  {
    q: "Can I use it with OpenAI or another API?",
    a: (
      <>
        Yes: any OpenAI-compatible endpoint is a model entry with a <code>base_url</code>. Handy for comparing
        quality, though then your data leaves your Google Cloud project.
      </>
    ),
  },
];

export function Faq() {
  return (
    <section id="faq" className={`${styles.section} ${styles.sectionAlt}`}>
      <div className={styles.container}>
        <div className={`${styles.sectionHead} ${styles.sectionHeadCenter}`}>
          <span className={styles.eyebrow}>FAQ</span>
          <h2 className={styles.h2}>Questions people ask</h2>
        </div>
        <div className={styles.faq}>
          {QUESTIONS.map(({ q, a }) => (
            <details key={q} className={styles.faqItem}>
              <summary>
                {q}
                <ChevronDown size={18} aria-hidden className={styles.faqChevron} />
              </summary>
              <div className={styles.faqAnswer}>{a}</div>
            </details>
          ))}
        </div>
      </div>
    </section>
  );
}
