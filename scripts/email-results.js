import { readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import nodemailer from "nodemailer";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const config = JSON.parse(readFileSync(path.join(root, "config/assignment.json"), "utf8"));
const results = JSON.parse(readFileSync(path.join(root, "results/grading-results.json"), "utf8"));
const students = JSON.parse(readFileSync(path.join(root, "results/students.json"), "utf8"));
const dryRun = process.argv.includes("--dry-run") || String(process.env.EMAIL_DRY_RUN || "").toLowerCase() === "true";
const gmailUser = String(process.env.GMAIL_USER || "").trim();
const gmailAppPassword = String(process.env.GMAIL_APP_PASSWORD || "").replace(/\s+/g, "");
const fromName = cleanHeader(process.env.EMAIL_FROM_NAME || "CC Autograder");
const replyTo = String(process.env.EMAIL_REPLY_TO || "").trim();

if (!Array.isArray(results) || !results.length) throw new Error("No grading results found.");
if (!Array.isArray(students) || !students.length) throw new Error("No trusted students found.");
if (!dryRun && (!isEmail(gmailUser) || !gmailAppPassword)) {
  throw new Error("GMAIL_USER and GMAIL_APP_PASSWORD GitHub secrets are required to send email.");
}
if (replyTo && !isEmail(replyTo)) throw new Error("EMAIL_REPLY_TO must be a valid email address.");

const trusted = new Map(students.map((student) => [String(student.github_username).trim().toLowerCase(), student]));
const messages = [];

for (const result of results) {
  const student = validateResult(result, trusted, config);
  const recipient = String(student.email || "").trim();
  if (!isEmail(recipient)) {
    console.warn(`Skipping ${safeLog(student.registration_number)}: no valid student email address.`);
    continue;
  }

  messages.push(buildMessage({ config, result, student, recipient, gmailUser, fromName, replyTo }));
}

if (!messages.length) throw new Error("No students with valid email addresses were available.");

if (dryRun) {
  for (const message of messages) {
    console.log(`Prepared email for ${safeLog(message.registrationNumber)} with ${message.checkCount} result rows.`);
  }
  console.log(`Email dry run complete: ${messages.length} prepared, 0 sent.`);
  process.exit(0);
}

const transporter = nodemailer.createTransport({
  service: "gmail",
  pool: true,
  maxConnections: 1,
  maxMessages: 100,
  rateDelta: 1000,
  rateLimit: 1,
  auth: { user: gmailUser, pass: gmailAppPassword }
});

await transporter.verify();
const failures = [];

for (const message of messages) {
  try {
    await transporter.sendMail(message.mail);
    console.log(`Sent ${safeLog(config.category)}/${safeLog(config.assessment)} result to ${safeLog(message.registrationNumber)}.`);
  } catch (error) {
    failures.push(message.registrationNumber);
    console.error(`Could not email ${safeLog(message.registrationNumber)}: ${safeLog(error.message)}`);
  }
}

transporter.close();
console.log(`Email delivery complete: ${messages.length - failures.length} sent, ${failures.length} failed.`);
if (failures.length) throw new Error(`Email delivery failed for: ${failures.map(safeLog).join(", ")}`);

function validateResult(result, trustedStudents, assignment) {
  const student = trustedStudents.get(String(result.github_username || "").trim().toLowerCase());
  if (!student || result.firebase_uid !== student.firebase_uid || result.enrollment_path !== student.enrollment_path) {
    throw new Error(`Untrusted result for ${safeLog(result.github_username)}.`);
  }
  if (
    String(result.course_code).toLowerCase() !== String(assignment.courseCode).toLowerCase()
    || result.category !== assignment.category
    || result.assessment !== assignment.assessment
  ) {
    throw new Error(`Configuration mismatch for ${safeLog(result.github_username)}.`);
  }
  if (String(result.repository).toLowerCase() !== `${student.github_username}/${assignment.repositoryName}`.toLowerCase()) {
    throw new Error(`Repository mismatch for ${safeLog(result.github_username)}.`);
  }
  if (!["graded", "error"].includes(result.status)) throw new Error(`Unknown grading status for ${safeLog(result.github_username)}.`);
  if (result.status === "graded") {
    if (!Number.isFinite(result.obtained) || !Number.isFinite(result.total) || result.obtained < 0 || result.obtained > result.total) {
      throw new Error(`Invalid marks for ${safeLog(result.github_username)}.`);
    }
  }
  return student;
}

function buildMessage({ config: assignment, result, student, recipient, gmailUser: sender, fromName: senderName, replyTo: responseAddress }) {
  const registrationNumber = cleanHeader(student.registration_number || result.registration_number || "Student");
  const fullName = cleanHeader([student.first_name, student.last_name].map((value) => String(value || "").trim()).filter(Boolean).join(" "));
  const displayName = fullName || registrationNumber;
  const report = result.status === "graded" ? parseFeedback(result.feedback) : {
    summary: "Grading did not complete. Existing marks were not changed.",
    checks: [{ name: "Grading process", status: "Not graded", details: result.feedback || "Please contact your instructor." }]
  };
  if (!report.checks.length) {
    report.checks.push({ name: "Submission", status: result.status === "graded" ? "Failed" : "Not graded", details: result.feedback || "No detailed feedback was produced." });
  }

  const score = result.status === "graded" ? `${formatNumber(result.obtained)}/${formatNumber(result.total)}` : "Not graded";
  const subject = cleanHeader(`[${assignment.courseCode}] ${assignment.assessment} result - ${registrationNumber}`);
  const textRows = report.checks.map((check) => `- ${check.name}: ${check.status} - ${check.details}`).join("\n");
  const text = [
    `Dear ${displayName},`,
    "",
    `Your ${assignment.category}/${assignment.assessment} grading result is ${score}.`,
    report.summary,
    "",
    textRows,
    "",
    `Repository: ${result.repository}`,
    `Graded at: ${formatDate(result.graded_at)}`,
    "",
    "If you believe a required file was present or the evidence was misread, contact your instructor."
  ].join("\n");

  const rows = report.checks.map((check) => {
    const colors = statusColors(check.status);
    return `<tr>
      <td style="padding:10px;border:1px solid #d0d7de;font-family:Arial,sans-serif;word-break:break-word;">${escapeHtml(check.name)}</td>
      <td style="padding:10px;border:1px solid #d0d7de;font-family:Arial,sans-serif;font-weight:700;color:${colors.text};background:${colors.background};">${escapeHtml(check.status)}</td>
      <td style="padding:10px;border:1px solid #d0d7de;font-family:Arial,sans-serif;">${escapeHtml(check.details)}</td>
    </tr>`;
  }).join("\n");

  const html = `<!doctype html>
<html lang="en">
  <body style="margin:0;padding:0;background:#f6f8fa;color:#1f2328;">
    <div style="max-width:760px;margin:0 auto;padding:24px;">
      <div style="background:#ffffff;border:1px solid #d0d7de;border-radius:8px;padding:24px;">
        <h1 style="margin:0 0 8px;font:700 24px Arial,sans-serif;">${escapeHtml(assignment.assessment)} grading result</h1>
        <p style="margin:0 0 20px;font:14px Arial,sans-serif;color:#59636e;">${escapeHtml(assignment.courseCode)} &middot; ${escapeHtml(registrationNumber)}</p>
        <p style="font:16px Arial,sans-serif;">Dear ${escapeHtml(displayName)},</p>
        <div style="margin:20px 0;padding:16px;background:#eef6ff;border-left:4px solid #0969da;">
          <div style="font:13px Arial,sans-serif;color:#59636e;">Score</div>
          <div style="font:700 28px Arial,sans-serif;">${escapeHtml(score)}</div>
          <div style="margin-top:6px;font:14px Arial,sans-serif;">${escapeHtml(report.summary)}</div>
        </div>
        <table role="table" style="width:100%;border-collapse:collapse;border-spacing:0;">
          <thead>
            <tr style="background:#f6f8fa;">
              <th align="left" style="padding:10px;border:1px solid #d0d7de;font:700 14px Arial,sans-serif;">Check</th>
              <th align="left" style="padding:10px;border:1px solid #d0d7de;font:700 14px Arial,sans-serif;">Result</th>
              <th align="left" style="padding:10px;border:1px solid #d0d7de;font:700 14px Arial,sans-serif;">Explanation</th>
            </tr>
          </thead>
          <tbody>${rows}</tbody>
        </table>
        <p style="margin:20px 0 0;font:13px Arial,sans-serif;color:#59636e;">
          Repository: ${escapeHtml(result.repository)}<br>
          Graded at: ${escapeHtml(formatDate(result.graded_at))}
        </p>
        <p style="font:14px Arial,sans-serif;">If you believe a required file was present or the evidence was misread, contact your instructor.</p>
      </div>
    </div>
  </body>
</html>`;

  const headers = process.env.GITHUB_RUN_ID ? { "X-Autograder-Run-Id": cleanHeader(process.env.GITHUB_RUN_ID) } : undefined;
  return {
    registrationNumber,
    checkCount: report.checks.length,
    mail: {
      from: { name: senderName, address: sender },
      to: { name: displayName, address: recipient },
      ...(responseAddress ? { replyTo: responseAddress } : {}),
      subject,
      text,
      html,
      ...(headers ? { headers } : {})
    }
  };
}

function parseFeedback(feedback) {
  const value = String(feedback || "").trim();
  const summaryMatch = value.match(/^(Passed\s+\d+\/\d+[^.]*\.)\s*(.*)$/s);
  const summary = summaryMatch ? summaryMatch[1] : "Detailed grading feedback is shown below.";
  const details = summaryMatch ? summaryMatch[2] : value;
  const checks = details.split(";").map((entry) => entry.trim()).filter(Boolean).map((entry) => {
    const separator = entry.indexOf(":");
    if (separator < 1) return { name: "Submission", status: "Failed", details: stripZero(entry) };
    const name = entry.slice(0, separator).trim();
    const message = entry.slice(separator + 1).trim();
    if (/^passed$/i.test(message)) return { name, status: "Passed", details: "Required evidence detected." };
    if (/^missing\s*\(0\)$/i.test(message)) return { name, status: "Missing", details: "Required file was not found." };
    return { name, status: "Failed", details: sentence(stripZero(message)) };
  });
  return { summary, checks };
}

function stripZero(value) {
  return String(value || "").replace(/\s*\(0\)\s*$/, "").trim();
}

function sentence(value) {
  const text = String(value || "No explanation was produced.").trim();
  return `${text.charAt(0).toUpperCase()}${text.slice(1)}${/[.!?]$/.test(text) ? "" : "."}`;
}

function statusColors(status) {
  if (status === "Passed") return { text: "#116329", background: "#dafbe1" };
  if (status === "Missing") return { text: "#7d4e00", background: "#fff8c5" };
  return { text: "#a40e26", background: "#ffebe9" };
}

function formatNumber(value) {
  return Number(value).toLocaleString("en-US", { maximumFractionDigits: 2 });
}

function formatDate(value) {
  const date = new Date(value);
  return Number.isNaN(date.getTime()) ? String(value || "Unknown") : date.toISOString().replace("T", " ").replace(/\.\d{3}Z$/, " UTC");
}

function isEmail(value) {
  const email = String(value || "").trim();
  return email.length <= 254 && !/[\r\n]/.test(email) && /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email);
}

function cleanHeader(value) {
  return String(value || "").replace(/[\r\n]+/g, " ").trim().slice(0, 200);
}

function safeLog(value) {
  return String(value || "unknown").replace(/[\r\n]+/g, " ").slice(0, 100);
}

function escapeHtml(value) {
  return String(value ?? "").replace(/[&<>"']/g, (character) => ({
    "&": "&amp;",
    "<": "&lt;",
    ">": "&gt;",
    "\"": "&quot;",
    "'": "&#39;"
  })[character]);
}
