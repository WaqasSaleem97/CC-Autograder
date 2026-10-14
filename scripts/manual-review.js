import { createHash } from "node:crypto";
import { canonicalScreenshotName } from "./screenshot-normalization.js";

export const REVIEW_DECISIONS = new Set(["pending", "valid", "invalid", "review-later"]);

export function roundMark(value) {
  return Number(Number(value).toFixed(2));
}

export function resultKey(value = {}) {
  return String(
    value.enrollment_id
      || String(value.enrollment_path || "").split("/").filter(Boolean).at(-1)
      || value.firebase_uid
      || value.github_username
      || ""
  ).trim();
}

export function isCleanFullCreditReference(record = {}) {
  const automatic = Number(record.automaticPoints);
  const maximum = Number(record.maxPoints);
  return Boolean(record.source)
    && Boolean(record.hash)
    && record.automaticStatus === "Passed"
    && Number.isFinite(automatic)
    && Number.isFinite(maximum)
    && maximum > 0
    && Math.abs(automatic - maximum) < 0.000001
    && ["Automatic pass", "Passed quality-control sample"].includes(record.auditCategory)
    && (!Array.isArray(record.duplicateReferences) || record.duplicateReferences.length === 0);
}

export function buildReferenceCriteria(records = [], options = {}) {
  const studentImageUrl = typeof options.studentImageUrl === "function" ? options.studentImageUrl : () => "";
  const instructorImageUrl = typeof options.instructorImageUrl === "function" ? options.instructorImageUrl : () => "";
  const groups = new Map();

  for (const record of records) {
    const criterionId = String(record.criterionId || record.expectedName || "").trim();
    if (!criterionId) continue;
    if (!groups.has(criterionId)) {
      groups.set(criterionId, {
        id: createHash("sha256").update(criterionId).digest("hex").slice(0, 32),
        criterion_id: criterionId,
        criterion_order: Number.isFinite(Number(record.criterionOrder)) ? Number(record.criterionOrder) : Number.MAX_SAFE_INTEGER,
        criterion_label: String(record.criterionLabel || record.expectedName || "Evidence"),
        expected_filename: String(record.expectedName || ""),
        expected_evidence: Array.isArray(record.expectedEvidence) ? record.expectedEvidence.map(String) : [],
        reference_candidates: []
      });
    }

    if (!isCleanFullCreditReference(record)) continue;
    const imageUrl = String(studentImageUrl(record) || "").trim();
    if (!imageUrl) continue;
    const group = groups.get(criterionId);
    group.reference_candidates.push({
      id: createHash("sha256").update(`${criterionId}|${record.enrollmentId}|${record.hash}`).digest("hex").slice(0, 32),
      source: "student-full-credit",
      label: `${record.registration || "No registration"} · ${record.username || "No username"}`,
      registration_number: String(record.registration || ""),
      github_username: String(record.username || ""),
      image_url: imageUrl,
      submitted_path: String(record.submittedPath || ""),
      image_sha256: String(record.hash || ""),
      automatic_points: Number(record.automaticPoints),
      max_points: Number(record.maxPoints)
    });
  }

  return [...groups.values()].map((group) => {
    const firstRecord = records.find((record) => String(record.criterionId || record.expectedName || "").trim() === group.criterion_id);
    const instructorUrl = String(instructorImageUrl(firstRecord || {}) || "").trim();
    if (instructorUrl) {
      group.reference_candidates.unshift({
        id: createHash("sha256").update(`${group.criterion_id}|instructor|${instructorUrl}`).digest("hex").slice(0, 32),
        source: "instructor",
        label: "Instructor reference",
        registration_number: "",
        github_username: "",
        image_url: instructorUrl,
        submitted_path: group.expected_filename,
        image_sha256: "",
        automatic_points: null,
        max_points: null
      });
    }
    group.reference_candidates.sort((left, right) => {
      if (left.source !== right.source) return left.source === "instructor" ? -1 : 1;
      return left.label.localeCompare(right.label) || left.id.localeCompare(right.id);
    });
    group.reference_candidate_ids = group.reference_candidates.map((candidate) => candidate.id);
    group.selected_reference_ids = [...group.reference_candidate_ids];
    return group;
  }).sort((left, right) => left.criterion_order - right.criterion_order || left.criterion_label.localeCompare(right.criterion_label));
}

export function targetPoints(item) {
  if (item.decision === "valid") return Number(item.max_points);
  if (item.decision === "invalid") return 0;
  throw new Error(`${item.id || item.expected_filename || "Review item"} has not received a final decision.`);
}

export function applyReviewDecisions(results, items) {
  if (!Array.isArray(results) || !results.length) throw new Error("No staged grading results were found.");
  if (!Array.isArray(items)) throw new Error("Review items must be an array.");

  const unresolved = items.filter((item) => !["valid", "invalid"].includes(item.decision));
  if (unresolved.length) {
    throw new Error(`${unresolved.length} review item(s) are still pending or marked Review later.`);
  }

  const itemsByResult = new Map();
  for (const item of items) {
    if (!REVIEW_DECISIONS.has(item.decision)) throw new Error(`Invalid review decision: ${item.decision}`);
    const key = resultKey(item);
    if (!key) throw new Error("A review item has no enrollment identifier.");
    if (!itemsByResult.has(key)) itemsByResult.set(key, []);
    itemsByResult.get(key).push(item);
  }

  return results.map((source) => {
    const result = structuredClone(source);
    const resultItems = itemsByResult.get(resultKey(result)) || [];
    if (!resultItems.length) {
      result.review_count = 0;
      result.review_required = false;
      return result;
    }
    if (result.status !== "graded") throw new Error(`Cannot review an ungraded result for ${result.github_username}.`);

    let delta = 0;
    for (const item of resultItems) {
      const automatic = Number(item.automatic_points);
      const maximum = Number(item.max_points);
      if (!Number.isFinite(automatic) || !Number.isFinite(maximum) || automatic < 0 || maximum <= 0 || automatic > maximum) {
        throw new Error(`Invalid point values for ${item.expected_filename || item.id}.`);
      }
      delta += targetPoints(item) - automatic;
    }

    result.automatic_obtained = Number(result.obtained);
    if (Number.isFinite(Number(result.review_base_points)) && Array.isArray(result.review_items) && result.review_items.length) {
      const decisions = new Map(resultItems.map((item) => [canonicalScreenshotName(item.expected_filename), item]));
      const reviewedComponent = result.review_items.reduce((sum, criterion) => {
        const decision = decisions.get(canonicalScreenshotName(criterion.expected_filename));
        return sum + (decision ? targetPoints(decision) : Number(criterion.automatic_points));
      }, 0);
      result.obtained = roundMark(Math.min(Number(result.total), Math.max(0, Number(result.review_base_points) + reviewedComponent)));
    } else {
      result.obtained = roundMark(Math.min(Number(result.total), Math.max(0, Number(result.obtained) + delta)));
    }
    result.review_count = 0;
    result.review_required = false;
    result.manual_review_completed = true;
    result.manual_review_changes = resultItems.map((item) => ({
      criterion_id: item.criterion_id,
      expected_filename: item.expected_filename,
      decision: item.decision,
      automatic_points: Number(item.automatic_points),
      final_points: targetPoints(item),
      max_points: Number(item.max_points),
      reviewer_note: String(item.reviewer_note || "")
    }));
    result.feedback = reviewedFeedback(result.feedback, resultItems, result.obtained, result.total);
    return result;
  });
}

export function reviewedFeedback(feedback, items, obtained, total) {
  const source = String(feedback || "");
  const firstImage = source.search(/[^\s;:]+\.(?:jpeg|jpg|png|webp|bmp|tiff|tif|gif)\s*:/i);
  let details = firstImage >= 0 ? source.slice(firstImage) : source;
  const decisions = new Map(items.map((item) => [canonicalScreenshotName(item.expected_filename), item.decision]));

  details = details.split(";").map((entry) => {
    const match = entry.match(/(?:^|\s)([^\s;:]+\.(?:jpeg|jpg|png|webp|bmp|tiff|tif|gif))\s*:/i);
    if (!match) return entry.trim();
    const canonical = canonicalScreenshotName(match[1]);
    const decision = decisions.get(canonical);
    if (!decision) return entry.trim();
    return decision === "valid"
      ? `${match[1]}: passed after manual review`
      : `${match[1]}: failed after manual review (0)`;
  }).filter(Boolean).join("; ");

  return `Final score ${roundMark(obtained)}/${roundMark(total)} after manual review. ${details}`.trim();
}
