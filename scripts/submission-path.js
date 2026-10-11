import {
  existsSync,
  mkdirSync,
  renameSync,
  statSync
} from "node:fs";
import path from "node:path";

const ASSIGNMENT01_PATH = "Assignments/Assignment01";

const pathParts = (value) => String(value || "")
  .replaceAll("\\", "/")
  .split("/")
  .filter(Boolean);

const isDirectory = (candidate) => {
  try {
    return existsSync(candidate) && statSync(candidate).isDirectory();
  } catch {
    return false;
  }
};

export function submissionCandidates(repository, submissionPath, repositoryName) {
  const normalizedPath = pathParts(submissionPath).join("/");
  const candidates = [{
    path: path.join(repository, ...pathParts(submissionPath)),
    relativePath: normalizedPath
  }];

  // These two human folder-layout mistakes were observed in Assignment01 run
  // #55. Keep the exception deliberately narrow so unrelated directories are
  // never treated as submissions.
  if (normalizedPath === ASSIGNMENT01_PATH) {
    candidates.push(
      {
        path: path.join(repository, "Assignment", "Assignment01"),
        relativePath: "Assignment/Assignment01"
      },
      {
        path: path.join(
          repository,
          repositoryName,
          "Assignments",
          "Assignment01"
        ),
        relativePath: `${repositoryName}/Assignments/Assignment01`
      }
    );
  }

  return candidates;
}

export function findSubmissionDirectory(repository, submissionPath, repositoryName) {
  return submissionCandidates(repository, submissionPath, repositoryName)
    .find((candidate) => isDirectory(candidate.path)) || null;
}

export function normalizeSubmissionDirectory(repository, submissionPath, repositoryName) {
  const candidates = submissionCandidates(
    repository,
    submissionPath,
    repositoryName
  );
  const expected = candidates[0];
  const found = candidates.find((candidate) => isDirectory(candidate.path));

  if (!found || found.path === expected.path) {
    return {
      path: expected.path,
      originalRelativePath: null
    };
  }

  // Repositories are disposable workflow clones. Moving an accepted alternate
  // to the canonical path also keeps duplicate-image checks consistent across
  // every student without changing any student's GitHub repository.
  mkdirSync(path.dirname(expected.path), { recursive: true });
  renameSync(found.path, expected.path);
  return {
    path: expected.path,
    originalRelativePath: found.relativePath
  };
}
