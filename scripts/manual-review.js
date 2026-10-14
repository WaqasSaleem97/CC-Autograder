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
