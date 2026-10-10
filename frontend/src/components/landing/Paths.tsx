import { Fragment } from "react";
import Link from "next/link";
import { ArrowRight, Clock, Coins } from "lucide-react";
import styles from "./landing.module.css";

const LEVELS = [
  {
    title: "Your laptop, with a real model",
    text: "The full app on your laptop, with an open-source model you pick (Qwen, Gemma, Llama). No GPU needed.",
    commands: ["make up"],
    time: "15–30 min",
    cost: "free",
    href: "/docs/01-quickstart-local",
  },
  {
    title: "More models, faster",
    text: "Switch models, and run them on your Mac's or PC's GPU with Docker Model Runner.",
    commands: ["make model"],
    time: "10 min",
    cost: "free",
    href: "/docs/02-run-a-real-model-locally",
  },
  {
    title: "Your GPU on Cloud Run",
    text: "A private model on a Cloud Run GPU in your Google Cloud project, used by the app still on your laptop.",
    commands: ["make gcp-login", "make model-deploy", "make up-cloud"],
    time: "30 min",
    cost: "~$1.05–1.42 per hour awake, $0 asleep",
    href: "/docs/03-deploy-a-model-on-cloud-run",
  },
  {
    title: "Everything on Google Cloud",
    text: "The app on a public HTTPS URL for your team, with a GPU that sleeps when nobody chats.",
    commands: ["make deploy"],
    time: "1–2 h",
    cost: "~$12–15/month + GPU hours",
    href: "/docs/04-deploy-the-full-stack-on-google-cloud",
  },
  {
    title: "Advanced",
    text: "Always-warm GPUs, a 32B model on the 96 GB RTX PRO 6000, your own domain, faster wake-ups, CI/CD.",
    commands: [],
    time: "as you go",
    cost: "depends",
    href: "/docs/05-advanced",
  },
];

export function Paths() {
  return (
    <section id="paths" className={styles.section}>
      <div className={styles.container}>
        <div className={styles.sectionHead}>
          <span className={styles.eyebrow}>Choose your path</span>
          <h2 className={styles.h2}>From a laptop demo to production, one step at a time</h2>
          <p className={styles.lead}>Each level builds on the previous one. Stop wherever you have what you need.</p>
        </div>
        <ol className={styles.paths}>
          {LEVELS.map((level, index) => (
            <li key={level.href}>
              <Link href={level.href} className={styles.path}>
                <span className={styles.pathLevel} aria-hidden>
                  {index + 1}
                </span>
                <span>
                  <span className={styles.pathTitle}>
                    <span className="sr-only">Level {index + 1}: </span>
                    {level.title}
                  </span>
                  <span className={styles.pathText} style={{ display: "block" }}>
                    {level.text}
                  </span>
                  {level.commands.length > 0 && (
                    <span className={styles.pathText} style={{ display: "block", marginTop: 6 }}>
                      {level.commands.map((command, i) => (
                        <Fragment key={command}>
                          {i > 0 && " · "}
                          <code>{command}</code>
                        </Fragment>
                      ))}
                    </span>
                  )}
                  <span className={styles.chips}>
                    <span className={styles.chip}>
                      <Clock size={13} aria-hidden /> {level.time}
                    </span>
                    <span className={styles.chip}>
                      <Coins size={13} aria-hidden /> {level.cost}
                    </span>
                  </span>
                </span>
                <ArrowRight size={20} aria-hidden className={styles.pathArrow} />
              </Link>
            </li>
          ))}
        </ol>
      </div>
    </section>
  );
}
