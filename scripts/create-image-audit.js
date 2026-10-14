import { createHash } from "node:crypto";
import { execFileSync } from "node:child_process";
import {
  appendFileSync,
  copyFileSync,
  existsSync,
  mkdirSync,
  readFileSync,
  readdirSync,
  rmSync,
  statSync,
  writeFileSync
} from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { buildReferenceCriteria } from "./manual-review.js";
import { canonicalScreenshotName } from "./screenshot-normalization.js";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const argument = (name) => {
  const index = process.argv.indexOf(name);
  return index >= 0 ? process.argv[index + 1] : undefined;
};
const requestedScope = String(argument("--scope") || process.env.IMAGE_AUDIT_SCOPE || "Risk-based sample").trim();
const scope = /^all/i.test(requestedScope) ? "all" : "risk";
const config = JSON.parse(readFileSync(path.join(root, "config/assignment.json"), "utf8"));
const results = JSON.parse(readFileSync(path.join(root, "results/grading-results.json"), "utf8"));
const reportRoot = path.join(root, "results/image-audit");
const imagesRoot = path.join(reportRoot, "images");
const imageExtension = /\.(?:jpeg|jpg|png|webp|bmp|tiff|tif|gif)$/i;
const skippedDirectories = new Set([
  ".git",
  "node_modules",
  ".autograder-ignored-screenshot-name-collisions",
  ".autograder-ignored-screenshot-folder-collisions"
]);

const safeName = (value) => String(value || "unknown")
  .trim()
  .replace(/[^A-Za-z0-9._-]+/g, "-")
  .replace(/^-+|-+$/g, "") || "unknown";

const escapeHtml = (value) => String(value ?? "")
  .replaceAll("&", "&amp;")
  .replaceAll("<", "&lt;")
  .replaceAll(">", "&gt;")
  .replaceAll('"', "&quot;")
  .replaceAll("'", "&#39;");

const jsonForScript = (value) => JSON.stringify(value)
  .replaceAll("<", "\\u003c")
  .replaceAll(">", "\\u003e")
  .replaceAll("&", "\\u0026");

const truncate = (value, length = 14_000) => {
  const text = String(value || "").trim();
  return text.length > length ? `${text.slice(0, length)}\n\n[OCR text truncated]` : text;
};

function redactPotentialCredentials(value) {
  return truncate(value)
    .replace(/-----BEGIN[\s\S]{0,80}?PRIVATE KEY-----[\s\S]*?-----END[\s\S]{0,80}?PRIVATE KEY-----/gi, "[REDACTED PRIVATE KEY]")
    .replace(/\b(?:ghp_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,})\b/g, "[REDACTED GITHUB TOKEN]")
    .replace(/\b(?:AKIA|ASIA)[A-Z0-9]{16}\b/g, "[REDACTED AWS ACCESS KEY]")
    .replace(/\b(?:authorization\s*:\s*)?(?:bearer|token)\s+[A-Za-z0-9._~+\/-]{12,}/gi, "[REDACTED AUTHORIZATION TOKEN]")
    .replace(/https?:\/\/[^\s/@:]+:[^\s/@]{6,}@/gi, "https://[REDACTED-CREDENTIALS]@");
}

function feedbackChecks(feedback) {
  const text = String(feedback || "").trim();
  return text.split(";").map((entry) => entry.trim()).filter(Boolean).flatMap((entry) => {
    // Summary text can precede the first `filename: result` pair. Match the
    // final filename token before the separator instead of assuming that every
    // grader uses the same summary sentence.
    const match = entry.match(/(?:^|\s)([^\s;:]+\.(?:jpeg|jpg|png|webp|bmp|tiff|tif|gif))\s*:\s*(.*)$/i);
    if (!match) return [];
    const [, name, message] = match;

    let status = "Failed";
    if (/^(?:passed|optional bonus passed)\b/i.test(message)) status = "Passed";
    else if (/^partial credit\b/i.test(message)) status = "Partial credit";
    else if (/^manual review\b/i.test(message)) status = "Manual review";
    else if (/^missing\b/i.test(message)) status = "Missing";

    const canonical = canonicalScreenshotName(path.basename(name));
    return canonical ? [{ name, canonical, status, message }] : [];
  });
}

function walkImages(directory) {
  if (!existsSync(directory) || !statSync(directory).isDirectory()) return [];
  const images = [];
  const visit = (current) => {
    for (const entry of readdirSync(current, { withFileTypes: true })) {
      if (entry.name.startsWith(".autograder-ignored-") || skippedDirectories.has(entry.name)) continue;
      const location = path.join(current, entry.name);
      if (entry.isDirectory()) visit(location);
      else if (entry.isFile() && imageExtension.test(entry.name)) images.push(location);
    }
  };
  visit(directory);
  return images;
}

function sha256(file) {
  return createHash("sha256").update(readFileSync(file)).digest("hex");
}

function detectedImageExtension(file) {
  const header = readFileSync(file).subarray(0, 16);
  if (header.length >= 8 && header.subarray(0, 8).equals(Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]))) return "png";
  if (header.length >= 3 && header[0] === 0xff && header[1] === 0xd8 && header[2] === 0xff) return "jpg";
  if (header.subarray(0, 6).toString("ascii").match(/^GIF8[79]a$/)) return "gif";
  if (header.subarray(0, 4).toString("ascii") === "RIFF" && header.subarray(8, 12).toString("ascii") === "WEBP") return "webp";
  if (header.subarray(0, 2).toString("ascii") === "BM") return "bmp";
  const tiff = header.subarray(0, 4).toString("hex");
  if (tiff === "49492a00" || tiff === "4d4d002a") return "tiff";
  return "img";
}

function findOcrText(studentKey, filename) {
  if (!filename) return "";
  const directory = path.join(root, "results/ocr-audit", studentKey);
  if (!existsSync(directory)) return "";
  const expected = `${path.basename(filename, path.extname(filename))}.txt`.toLowerCase();
  const match = readdirSync(directory).find((name) => name.toLowerCase() === expected);
  return match ? redactPotentialCredentials(readFileSync(path.join(directory, match), "utf8")) : "";
}

function inferredCheckCount(result) {
  const match = String(result.feedback || "").match(/(?:Passed|Earned)\s+[0-9.]+\/([0-9]+)/i);
  return match ? Number(match[1]) : 0;
}

function defaultExpectedEvidence(filename) {
  return [
    `Submit the required screenshot named ${filename} (capitalization and repeated image extensions are ignored).`,
    "The image must clearly show the task-specific command or page and its successful result.",
    "Compare against the selected clean full-credit examples or instructor reference when available; otherwise use the written requirement shown here."
  ];
}

const repositoryCache = new Map();
function repositoryMetadata(username) {
  if (repositoryCache.has(username)) return repositoryCache.get(username);
  const repository = path.join(root, "work/submissions", username, config.repositoryName);
  try {
    const commit = execFileSync("git", ["rev-parse", "HEAD"], { cwd: repository, encoding: "utf8" }).trim();
    const tree = execFileSync("git", ["ls-tree", "-r", "-z", "HEAD"], { cwd: repository, encoding: "utf8", maxBuffer: 64 * 1024 * 1024 });
    const pathsByBlob = new Map();
    for (const entry of tree.split("\0").filter(Boolean)) {
      const match = entry.match(/^\d+\s+blob\s+([0-9a-f]+)\t([\s\S]+)$/);
      if (!match) continue;
      if (!pathsByBlob.has(match[1])) pathsByBlob.set(match[1], []);
      pathsByBlob.get(match[1]).push(match[2]);
    }
    const value = { repository, commit, pathsByBlob };
    repositoryCache.set(username, value);
    return value;
  } catch {
    const value = null;
    repositoryCache.set(username, value);
    return value;
  }
}

function rawStudentImageUrl(record) {
  if (!record.source) return "";
  const metadata = repositoryMetadata(record.username);
  if (!metadata) return "";
  try {
    const blob = execFileSync("git", ["hash-object", record.source], { cwd: metadata.repository, encoding: "utf8" }).trim();
    const expectedCanonical = canonicalScreenshotName(record.expectedName);
    const submissionPrefix = `${config.submissionPath.toLowerCase()}/`;
    const candidates = [...(metadata.pathsByBlob.get(blob) || [])].sort((left, right) => {
      const score = (candidate) =>
        (canonicalScreenshotName(path.posix.basename(candidate)) === expectedCanonical ? 4 : 0)
        + (candidate.toLowerCase().startsWith(submissionPrefix) ? 2 : 0)
        + (candidate.toLowerCase().includes("/screenshots/") ? 1 : 0);
      return score(right) - score(left) || left.localeCompare(right);
    });
    if (!candidates.length) return "";
    const encodedPath = candidates[0].split("/").map(encodeURIComponent).join("/");
    return `https://raw.githubusercontent.com/${encodeURIComponent(record.username)}/${encodeURIComponent(config.repositoryName)}/${metadata.commit}/${encodedPath}`;
  } catch {
    return "";
  }
}

function referenceImageUrl(expectedName) {
  const directory = path.join(root, path.dirname(config.testScript), "expected");
  if (!existsSync(directory)) return "";
  const expectedCanonical = canonicalScreenshotName(expectedName);
  const match = walkImages(directory).find((file) => canonicalScreenshotName(path.basename(file)) === expectedCanonical);
  if (!match) return "";
  try {
    const repository = String(process.env.GITHUB_REPOSITORY || "WaqasSaleem97/CC-Autograder");
    const commit = String(process.env.GITHUB_SHA || execFileSync("git", ["rev-parse", "HEAD"], { cwd: root, encoding: "utf8" }).trim());
    const relative = path.relative(root, match).split(path.sep).map(encodeURIComponent).join("/");
    return `https://raw.githubusercontent.com/${repository.split("/").map(encodeURIComponent).join("/")}/${commit}/${relative}`;
  } catch {
    return "";
  }
}

const records = [];
for (const result of results) {
  const username = String(result.github_username || "").trim();
  const registration = String(result.registration_number || "").trim();
  const studentKey = safeName(registration || username);
  const submission = path.join(
    root,
    "work/submissions",
    username,
    config.repositoryName,
    ...config.submissionPath.split("/")
  );
  const checks = feedbackChecks(result.feedback);
  const expected = new Map(checks.map((check) => [check.canonical, check]));
  const structuredItems = new Map((Array.isArray(result.review_items) ? result.review_items : []).map((item) => [canonicalScreenshotName(item.expected_filename), item]));
  const checkCount = inferredCheckCount(result) || checks.length;
  const actualImages = walkImages(submission).filter((file) => {
    const canonical = canonicalScreenshotName(path.basename(file));
    const relativeParts = path.relative(submission, file).split(path.sep).map((part) => part.toLowerCase());
    return expected.has(canonical) || relativeParts.includes("screenshots");
  });
  const matched = new Set();

  for (const source of actualImages) {
    const canonical = canonicalScreenshotName(path.basename(source));
    const check = expected.get(canonical);
    const structured = structuredItems.get(canonical);
    if (check) matched.add(canonical);
    records.push({
      registration,
      username,
      studentKey,
      score: result.status === "graded" ? `${result.obtained}/${result.total}` : "NOT GRADED",
      source,
      expectedName: check?.name || path.basename(source),
      submittedPath: path.relative(submission, source).split(path.sep).join("/"),
      automaticStatus: check?.status || "Unmatched",
      automaticReason: check?.message || "Image was found, but no image check in the grader feedback matched its filename.",
      enrollmentId: result.enrollment_id || String(result.enrollment_path || "").split("/").at(-1) || result.firebase_uid,
      firebaseUid: result.firebase_uid,
      criterionId: String(structured?.criterion_id || canonical || path.basename(source)),
      criterionOrder: Number.isInteger(Number(structured?.criterion_order)) ? Number(structured.criterion_order) : Math.max(0, checks.findIndex((item) => item.canonical === canonical)),
      criterionLabel: String(structured?.criterion_label || path.basename(check?.name || source).replace(/\.[^.]+$/, "").replaceAll("_", " ")),
      expectedEvidence: structured?.expected_evidence?.length ? structured.expected_evidence : defaultExpectedEvidence(check?.name || path.basename(source)),
      automaticPoints: Number.isFinite(Number(structured?.automatic_points))
        ? Number(structured.automatic_points)
        : (["Passed", "Manual review"].includes(check?.status) && checkCount ? Number(result.total) / checkCount : 0),
      maxPoints: Number.isFinite(Number(structured?.max_points))
        ? Number(structured.max_points)
        : (checkCount ? Number(result.total) / checkCount : 0),
      hash: sha256(source),
      ocr: findOcrText(studentKey, check?.name || path.basename(source))
    });
  }

  for (const check of checks) {
    if (matched.has(check.canonical) || check.status !== "Missing") continue;
    records.push({
      registration,
      username,
      studentKey,
      score: result.status === "graded" ? `${result.obtained}/${result.total}` : "NOT GRADED",
      source: null,
      expectedName: check.name,
      submittedPath: "Not found",
      automaticStatus: check.status,
      automaticReason: check.message,
      enrollmentId: result.enrollment_id || String(result.enrollment_path || "").split("/").at(-1) || result.firebase_uid,
      firebaseUid: result.firebase_uid,
      criterionId: String(structuredItems.get(check.canonical)?.criterion_id || check.canonical),
      criterionOrder: Number.isInteger(Number(structuredItems.get(check.canonical)?.criterion_order)) ? Number(structuredItems.get(check.canonical).criterion_order) : Math.max(0, checks.findIndex((item) => item.canonical === check.canonical)),
      criterionLabel: String(structuredItems.get(check.canonical)?.criterion_label || check.name.replace(/\.[^.]+$/, "").replaceAll("_", " ")),
      expectedEvidence: structuredItems.get(check.canonical)?.expected_evidence?.length ? structuredItems.get(check.canonical).expected_evidence : defaultExpectedEvidence(check.name),
      automaticPoints: Number(structuredItems.get(check.canonical)?.automatic_points || 0),
      maxPoints: Number(structuredItems.get(check.canonical)?.max_points || (checkCount ? Number(result.total) / checkCount : 0)),
      hash: "",
      ocr: ""
    });
  }
}

const hashGroups = new Map();
for (const record of records) {
  if (!record.hash) continue;
  if (!hashGroups.has(record.hash)) hashGroups.set(record.hash, []);
  hashGroups.get(record.hash).push(record);
}

for (const record of records) {
  const duplicates = record.hash ? hashGroups.get(record.hash) || [] : [];
  const meaningfulDuplicates = duplicates.filter((other) =>
    other !== record
    && (other.studentKey !== record.studentKey || other.expectedName.toLowerCase() !== record.expectedName.toLowerCase())
  );
  record.duplicateReferences = meaningfulDuplicates.map((other) => `${other.registration || other.username}: ${other.expectedName}`);

  if (!record.source) {
    record.auditCategory = "Missing expected screenshot";
    record.auditReason = "The grader expected this screenshot, but no matching image file was found.";
  } else if (["Failed", "Partial credit", "Manual review"].includes(record.automaticStatus)) {
    record.auditCategory = "Possible false negative";
    record.auditReason = "The image exists but did not receive an unqualified automatic pass.";
  } else if (record.automaticStatus === "Passed" && record.duplicateReferences.length) {
    record.auditCategory = "Possible false positive";
    record.auditReason = "The passed image is byte-identical to evidence used by another student or task.";
  } else if (record.automaticStatus === "Unmatched") {
    record.auditCategory = "Unmatched evidence";
    record.auditReason = "The image exists but could not be connected to an automatic grading check.";
  } else {
    record.auditCategory = "Automatic pass";
    record.auditReason = "The grader passed this screenshot; it is excluded from risk-based review and remains available as an expected-image reference.";
  }
}

const selected = scope === "all"
  ? records
  : records.filter((record) => record.auditCategory !== "Automatic pass");

rmSync(reportRoot, { recursive: true, force: true });
mkdirSync(imagesRoot, { recursive: true });

for (const [index, record] of selected.entries()) {
  if (!record.source) {
    record.reportImage = "";
    continue;
  }
  const extension = detectedImageExtension(record.source);
  const studentDirectory = path.join(imagesRoot, record.studentKey);
  mkdirSync(studentDirectory, { recursive: true });
  const filename = `${String(index + 1).padStart(4, "0")}-${safeName(path.basename(record.expectedName, path.extname(record.expectedName)))}.${extension}`;
  const destination = path.join(studentDirectory, filename);
  copyFileSync(record.source, destination);
  record.reportImage = path.relative(reportRoot, destination).split(path.sep).join("/");
}

const categoryOrder = [
  "Possible false negative",
  "Possible false positive",
  "Unmatched evidence",
  "Missing expected screenshot",
  "Automatic pass"
];
selected.sort((left, right) =>
  categoryOrder.indexOf(left.auditCategory) - categoryOrder.indexOf(right.auditCategory)
  || left.registration.localeCompare(right.registration)
  || left.expectedName.localeCompare(right.expectedName)
);

const reviewItems = selected
  .filter((record) => record.source && ["Possible false negative", "Possible false positive"].includes(record.auditCategory))
  .map((record) => ({
    id: createHash("sha256").update(`${record.enrollmentId}|${record.criterionId}|${record.hash}`).digest("hex").slice(0, 32),
    enrollment_id: record.enrollmentId,
    firebase_uid: record.firebaseUid,
    registration_number: record.registration,
    github_username: record.username,
    criterion_id: record.criterionId,
    criterion_order: record.criterionOrder,
    criterion_label: record.criterionLabel,
    expected_filename: record.expectedName,
    expected_evidence: record.expectedEvidence,
    reference_image_url: referenceImageUrl(record.expectedName),
    student_image_url: rawStudentImageUrl(record),
    submitted_path: record.submittedPath,
    audit_category: record.auditCategory,
    audit_reason: record.auditReason,
    automatic_status: record.automaticStatus,
    automatic_reason: record.automaticReason,
    automatic_points: Number(record.automaticPoints.toFixed(6)),
    max_points: Number(record.maxPoints.toFixed(6)),
    duplicate_references: record.duplicateReferences,
    ocr_text: record.ocr,
    image_sha256: record.hash,
    decision: "pending",
    reviewer_note: ""
  }));

writeFileSync(path.join(reportRoot, "review-items.json"), `${JSON.stringify(reviewItems, null, 2)}\n`);

const reviewedCriteria = new Set(reviewItems.map((item) => item.criterion_id));
const reviewCriteria = buildReferenceCriteria(records, {
  studentImageUrl: rawStudentImageUrl,
  instructorImageUrl: (record) => referenceImageUrl(record.expectedName)
}).filter((criterion) => reviewedCriteria.has(criterion.criterion_id));
writeFileSync(path.join(reportRoot, "review-criteria.json"), `${JSON.stringify(reviewCriteria, null, 2)}\n`);

const count = (category) => selected.filter((record) => record.auditCategory === category).length;
const cards = selected.map((record, index) => {
  const image = record.reportImage
    ? `<a class="preview" href="${escapeHtml(record.reportImage)}" target="_blank"><img src="${escapeHtml(record.reportImage)}" loading="lazy" alt="${escapeHtml(record.expectedName)}"></a>`
    : `<div class="preview missing-preview">No matching image</div>`;
  const duplicates = record.duplicateReferences.length
    ? `<details><summary>Identical-image matches (${record.duplicateReferences.length})</summary><ul>${record.duplicateReferences.map((item) => `<li>${escapeHtml(item)}</li>`).join("")}</ul></details>`
    : "";
  const ocr = record.ocr
    ? `<details><summary>OCR text used by the grader</summary><pre>${escapeHtml(record.ocr)}</pre></details>`
    : `<p class="muted">No saved OCR text was available. This can happen when the selected grader does not use the shared OCR helper.</p>`;
  const defaultDecision = "keep-auto";

  return `<article class="card" data-search="${escapeHtml(`${record.registration} ${record.username} ${record.expectedName} ${record.auditCategory} ${record.automaticStatus}`.toLowerCase())}" data-category="${escapeHtml(record.auditCategory)}" data-registration="${escapeHtml(record.registration)}" data-username="${escapeHtml(record.username)}" data-filename="${escapeHtml(record.expectedName)}" data-hash="${escapeHtml(record.hash)}" data-auto="${escapeHtml(record.automaticStatus)}">
    <header><div><h2>${escapeHtml(record.registration || "No registration")}</h2><p>${escapeHtml(record.username)}</p></div><span class="badge category-${safeName(record.auditCategory).toLowerCase()}">${escapeHtml(record.auditCategory)}</span></header>
    <div class="card-grid">
      ${image}
      <div class="evidence">
        <dl>
          <dt>Assessment</dt><dd>${escapeHtml(`${config.courseCode} · ${config.category} · ${config.assessment}`)}</dd>
          <dt>Student score</dt><dd>${escapeHtml(record.score)}</dd>
          <dt>Expected screenshot</dt><dd><code>${escapeHtml(record.expectedName)}</code></dd>
          <dt>Submitted path</dt><dd><code>${escapeHtml(record.submittedPath)}</code></dd>
          <dt>Automatic result</dt><dd><strong>${escapeHtml(record.automaticStatus)}</strong> — ${escapeHtml(record.automaticReason)}</dd>
          <dt>Why selected</dt><dd>${escapeHtml(record.auditReason)}</dd>
          <dt>SHA-256</dt><dd><code class="hash">${escapeHtml(record.hash || "No image hash")}</code></dd>
        </dl>
        ${duplicates}
        ${ocr}
        <fieldset>
          <legend>Manual audit decision</legend>
          ${[
            ["keep-auto", "Keep automatic result"],
            ["accept", "Accept evidence"],
            ["reject", "Reject evidence"],
            ["review-later", "Review later"]
          ].map(([value, label]) => `<label><input type="radio" name="decision-${index}" value="${value}" ${value === defaultDecision ? "checked" : ""}> ${label}</label>`).join("")}
          <label class="note-label">Reviewer note<textarea rows="2" placeholder="Brief reason for changing or confirming the result"></textarea></label>
        </fieldset>
      </div>
    </div>
  </article>`;
}).join("\n");

const createdAt = new Date().toISOString();
const runId = String(process.env.GITHUB_RUN_ID || createdAt);
const html = `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Image audit · ${escapeHtml(config.assessment)}</title>
<style>
:root{color-scheme:light;--border:#d0d7de;--muted:#57606a;--bg:#f6f8fa;--blue:#0969da;--red:#cf222e;--amber:#9a6700}*{box-sizing:border-box}body{margin:0;font:14px/1.5 -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;color:#1f2328;background:var(--bg)}main{max-width:1500px;margin:auto;padding:24px}.hero,.toolbar,.card{background:white;border:1px solid var(--border);border-radius:10px}.hero{padding:22px;margin-bottom:16px}.hero h1{margin:0 0 6px}.warning{border-left:4px solid var(--amber);padding:10px 12px;background:#fff8c5;margin:14px 0}.stats{display:flex;flex-wrap:wrap;gap:10px}.stat{min-width:145px;padding:10px 12px;border:1px solid var(--border);border-radius:8px}.stat strong{display:block;font-size:22px}.toolbar{position:sticky;top:0;z-index:3;display:flex;gap:10px;flex-wrap:wrap;padding:12px;margin-bottom:16px}.toolbar input,.toolbar select,.toolbar button,textarea{font:inherit}.toolbar input,.toolbar select{padding:8px;border:1px solid var(--border);border-radius:6px}.toolbar input{flex:1;min-width:240px}.toolbar button{color:white;background:var(--blue);border:0;border-radius:6px;padding:8px 14px;cursor:pointer}.card{padding:16px;margin-bottom:16px}.card>header{display:flex;justify-content:space-between;gap:12px;align-items:flex-start;border-bottom:1px solid var(--border);padding-bottom:10px;margin-bottom:14px}.card h2,.card p{margin:0}.badge{display:inline-block;padding:4px 8px;border-radius:20px;font-size:12px;font-weight:600;background:#ddf4ff;color:#0969da}.category-possible-false-negative{background:#ffebe9;color:var(--red)}.category-possible-false-positive{background:#fff8c5;color:var(--amber)}.category-missing-expected-screenshot{background:#fbefff;color:#8250df}.card-grid{display:grid;grid-template-columns:minmax(320px,48%) 1fr;gap:18px}.preview{min-height:220px;background:#24292f;border-radius:8px;display:flex;align-items:center;justify-content:center;overflow:auto}.preview img{display:block;max-width:100%;max-height:720px;object-fit:contain}.missing-preview{color:white}.evidence dl{display:grid;grid-template-columns:145px 1fr;gap:7px 10px;margin-top:0}.evidence dt{font-weight:600}.evidence dd{margin:0;min-width:0}.hash{overflow-wrap:anywhere}details{margin:12px 0}pre{max-height:320px;overflow:auto;white-space:pre-wrap;background:#f6f8fa;border:1px solid var(--border);padding:10px;border-radius:6px}fieldset{border:1px solid var(--border);border-radius:8px;padding:10px;display:flex;flex-wrap:wrap;gap:12px}fieldset label{white-space:nowrap}.note-label{width:100%;white-space:normal}textarea{display:block;width:100%;margin-top:5px;padding:7px;border:1px solid var(--border);border-radius:6px}.muted{color:var(--muted)}.empty{padding:40px;text-align:center;background:white;border:1px solid var(--border);border-radius:10px}@media(max-width:800px){main{padding:10px}.card-grid{grid-template-columns:1fr}.evidence dl{grid-template-columns:1fr}.evidence dt{margin-top:5px}}
</style>
</head>
<body><main>
<section class="hero">
  <h1>Manual image-audit report</h1>
  <p><strong>${escapeHtml(config.courseCode)} · ${escapeHtml(config.category)} · ${escapeHtml(config.assessment)}</strong> · ${escapeHtml(config.submissionPath)} · generated ${escapeHtml(createdAt)}</p>
  <div class="warning"><strong>This report does not change marks automatically.</strong> Inspect the actual image and the assignment criteria before overriding a result. “Accept evidence” is normally used for a false negative; “Reject evidence” is normally used for a false positive.</div>
  <p>Scope: <strong>${scope === "all" ? "all screenshots" : "risk-based cases only; clean automatic passes are excluded"}</strong>. OCR shown here is diagnostic only, and likely credentials are redacted from the displayed OCR text.</p>
  <div class="stats">
    <div class="stat"><strong>${results.length}</strong>students graded</div>
    <div class="stat"><strong>${selected.length}</strong>audit entries</div>
    <div class="stat"><strong>${count("Possible false negative")}</strong>possible false negatives</div>
    <div class="stat"><strong>${count("Possible false positive")}</strong>possible false positives</div>
  </div>
</section>
<section class="toolbar">
  <input id="search" type="search" placeholder="Search registration, username, or filename">
  <select id="category"><option value="">All audit categories</option>${categoryOrder.map((category) => `<option>${escapeHtml(category)}</option>`).join("")}</select>
  <button id="download" type="button">Download reviewed CSV</button>
</section>
<div id="cards">${cards || '<div class="empty">No screenshots matched this audit scope.</div>'}</div>
</main>
<script>
const storageKey=${jsonForScript(`image-audit-${runId}`)};
const cards=[...document.querySelectorAll('.card')];
const search=document.querySelector('#search');
const category=document.querySelector('#category');
function filter(){const term=search.value.trim().toLowerCase();const selected=category.value;for(const card of cards){card.hidden=Boolean((term&&!card.dataset.search.includes(term))||(selected&&card.dataset.category!==selected));}}
search.addEventListener('input',filter);category.addEventListener('change',filter);
function save(){const state=cards.map(card=>({hash:card.dataset.hash,filename:card.dataset.filename,decision:card.querySelector('input:checked').value,note:card.querySelector('textarea').value}));localStorage.setItem(storageKey,JSON.stringify(state));}
function restore(){try{const state=JSON.parse(localStorage.getItem(storageKey)||'[]');for(const saved of state){const card=cards.find(item=>item.dataset.hash===saved.hash&&item.dataset.filename===saved.filename);if(!card)continue;const radio=card.querySelector('input[value="'+CSS.escape(saved.decision)+'"]');if(radio)radio.checked=true;card.querySelector('textarea').value=saved.note||'';}}catch{}}
for(const card of cards){card.addEventListener('change',save);card.querySelector('textarea').addEventListener('input',save);}restore();
const csv=value=>'"'+String(value??'').replaceAll('"','""')+'"';
document.querySelector('#download').addEventListener('click',()=>{const rows=[['registration_number','github_username','course','category','assessment','screenshot','sha256','automatic_result','manual_decision','reviewer_note']];for(const card of cards){const decision=card.querySelector('input:checked').value;const note=card.querySelector('textarea').value.trim();if(decision==='keep-auto'&&!note)continue;rows.push([card.dataset.registration,card.dataset.username,${jsonForScript(config.courseCode)},${jsonForScript(config.category)},${jsonForScript(config.assessment)},card.dataset.filename,card.dataset.hash,card.dataset.auto,decision,note]);}const content=rows.map(row=>row.map(csv).join(',')).join('\r\n')+'\r\n';const blob=new Blob([content],{type:'text/csv;charset=utf-8'});const link=document.createElement('a');link.href=URL.createObjectURL(blob);link.download=${jsonForScript(`${safeName(config.courseCode)}-${safeName(config.assessment)}-manual-review.csv`)};link.click();URL.revokeObjectURL(link.href);});
</script>
</body></html>\n`;

writeFileSync(path.join(reportRoot, "index.html"), html);

const summaryLines = [
  "## Manual image audit",
  "",
  `- Scope: ${scope === "all" ? "all screenshots" : "risk-based cases only; clean automatic passes excluded"}`,
  `- Audit entries: ${selected.length}`,
  `- Possible false negatives: ${count("Possible false negative")}`,
  `- Possible false positives: ${count("Possible false positive")}`,
  `- Portal review decisions required: ${reviewItems.length}`,
  `- Expected-image pools prepared: ${reviewCriteria.length} (${reviewCriteria.reduce((total, criterion) => total + criterion.reference_candidates.length, 0)} clean full-credit or instructor reference image(s))`,
  "- Download the `image-audit-report` artifact and open `index.html` to review the evidence.",
  ""
].join("\n");
if (process.env.GITHUB_STEP_SUMMARY) appendFileSync(process.env.GITHUB_STEP_SUMMARY, summaryLines);
console.log(`Created ${scope} image-audit report with ${selected.length} entries, ${reviewItems.length} portal decisions, and ${reviewCriteria.length} expected-image pools for ${results.length} students.`);
