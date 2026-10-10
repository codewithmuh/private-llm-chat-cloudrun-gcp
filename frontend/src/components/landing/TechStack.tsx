import styles from "./landing.module.css";

const STACK: [string, string][] = [
  ["vLLM", "model serving"],
  ["Cloud Run", "GPUs, web, api"],
  ["Django 5.2", "API"],
  ["Django REST Framework", ""],
  ["Next.js 16", "web"],
  ["React 19", ""],
  ["TypeScript", ""],
  ["PostgreSQL", "Cloud SQL"],
  ["Cloud Storage", "files, weights"],
  ["Secret Manager", "secrets"],
  ["Cloud Build", "builds"],
  ["Artifact Registry", "images"],
  ["Terraform", "infrastructure"],
  ["Docker", ""],
  ["GitHub Actions", "CI/CD"],
  ["Ollama", "local models"],
];

export function TechStack() {
  return (
    <section className={styles.section} aria-labelledby="stack-title">
      <div className={styles.container}>
        <div className={`${styles.sectionHead} ${styles.sectionHeadCenter}`}>
          <span className={styles.eyebrow}>Tech stack</span>
          <h2 id="stack-title" className={styles.h2}>
            Boring, well-documented building blocks
          </h2>
        </div>
        <ul className={styles.stack}>
          {STACK.map(([name, note]) => (
            <li key={name} className={styles.stackItem}>
              {name}
              {note && <span>{note}</span>}
            </li>
          ))}
        </ul>
      </div>
    </section>
  );
}
