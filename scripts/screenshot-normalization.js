import {
  existsSync,
  mkdirSync,
  readdirSync,
  renameSync,
  statSync
} from "node:fs";
import path from "node:path";

const imageExtension = /\.\s*(?:jpeg|jpg|png|webp|bmp|tiff|tif|gif)\s*$/i;
const quarantineName = ".autograder-ignored-screenshot-name-collisions";
const folderQuarantineName = ".autograder-ignored-screenshot-folder-collisions";

export function canonicalScreenshotName(filename) {
  let stem = String(filename || "").trim();
  let image = false;

  while (imageExtension.test(stem)) {
    stem = stem.replace(imageExtension, "").trimEnd();
    image = true;
  }

  if (!image || !stem) return null;
  return `${stem.toLowerCase()}.png`;
}

function walkFiles(root) {
  const files = [];
  const visit = (directory) => {
    for (const entry of readdirSync(directory, { withFileTypes: true })) {
      const location = path.join(directory, entry.name);
      if (entry.isDirectory()) visit(location);
      else if (entry.isFile()) files.push(location);
    }
  };
  visit(root);
  return files;
}

function unusedQuarantinePath(directory, relativeDirectory, filename) {
  const targetDirectory = path.join(directory, relativeDirectory);
  mkdirSync(targetDirectory, { recursive: true });
  let target = path.join(targetDirectory, filename);
  let counter = 1;
  while (existsSync(target)) {
    target = path.join(targetDirectory, `${counter}-${filename}`);
    counter += 1;
  }
  return target;
}

/**
 * Find and normalize the immediate screenshots directory without treating a
 * capitalization mistake as a missing submission. The operation is performed
 * only in the disposable repository clone collected by the grading workflow.
 */
export function normalizeScreenshotsDirectory(submissionDirectory) {
  const submission = path.resolve(submissionDirectory);
  if (!existsSync(submission) || !statSync(submission).isDirectory()) return null;

  const canonical = path.join(submission, "screenshots");
  const matches = readdirSync(submission, { withFileTypes: true })
    .filter((entry) => entry.isDirectory() && entry.name.toLowerCase() === "screenshots")
    .map((entry) => path.join(submission, entry.name))
    .sort((left, right) => {
      const leftExact = left === canonical ? 0 : 1;
      const rightExact = right === canonical ? 0 : 1;
      return leftExact - rightExact || left.localeCompare(right);
    });

  if (matches.length === 0) return null;
  const [winner, ...duplicates] = matches;
  const quarantine = path.join(submission, folderQuarantineName);

  for (const duplicate of duplicates) {
    const destination = unusedQuarantinePath(
      quarantine,
      "",
      path.basename(duplicate)
    );
    renameSync(duplicate, destination);
  }

  if (winner !== canonical) renameSync(winner, canonical);
  return canonical;
}

/**
 * Normalize screenshot names inside an ephemeral collected repository.
 *
 * Students' remote repositories are never changed. Every recognized image is
 * exposed to trusted tests as a lowercase `<stem>.png` filename, regardless of
 * the submitted extension's case or whether it was repeated (for example,
 * `.PNG.png`). When multiple files normalize to the same name, the already
 * canonical file wins and the extras are moved outside `screenshots` so they
 * cannot create false duplicate-image matches.
 */
export function normalizeScreenshotFilenames(screenshotsDirectory) {
  const root = path.resolve(screenshotsDirectory);
  if (!existsSync(root) || !statSync(root).isDirectory()) {
    return { renamed: 0, ignoredDuplicates: 0 };
  }

  const groups = new Map();
  for (const source of walkFiles(root)) {
    const canonical = canonicalScreenshotName(path.basename(source));
    if (!canonical) continue;
    const target = path.join(path.dirname(source), canonical);
    const key = process.platform === "win32" ? target.toLowerCase() : target;
    if (!groups.has(key)) groups.set(key, { target, sources: [] });
    groups.get(key).sources.push(source);
  }

  const quarantine = path.join(path.dirname(root), quarantineName);
  let renamed = 0;
  let ignoredDuplicates = 0;

  for (const { target, sources } of groups.values()) {
    sources.sort((left, right) => {
      const leftExact = left === target ? 0 : 1;
      const rightExact = right === target ? 0 : 1;
      return leftExact - rightExact || left.localeCompare(right);
    });

    const [winner, ...duplicates] = sources;
    for (const duplicate of duplicates) {
      const relativeDirectory = path.relative(root, path.dirname(duplicate));
      const destination = unusedQuarantinePath(
        quarantine,
        relativeDirectory,
        path.basename(duplicate)
      );
      renameSync(duplicate, destination);
      ignoredDuplicates += 1;
    }

    if (winner !== target) {
      renameSync(winner, target);
      renamed += 1;
    }
  }

  return { renamed, ignoredDuplicates };
}
