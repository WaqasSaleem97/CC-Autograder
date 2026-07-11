# CC Autograder

Trusted GitHub Actions autograder for the multi-course Firebase Student Marks Portal.

This starter version grades one public repository at a time. It expects each student to create `GitHubUsername/CC` and place Lab 1 in `Labs/Lab1`.

## Security design

The workflow has two jobs:

1. `grade` downloads and executes untrusted student code without Firebase credentials.
2. `update-firestore` receives only a small JSON result and is the only job with Firebase access.

Never add Firebase credentials to the grading job or a student repository.

## Expected student structure

```text
CC/
├── Assignments/
├── Quizzes/
└── Labs/
    └── Lab1/
        └── main.py
```

The example `main.py` must print:

```text
Cloud Computing Lab 1
```

Change the rubric, paths, expected output and marks in `config/assignment.json` and `tests/Lab1/test.sh`.

## First test without Firebase

1. Create this repository as a **private** instructor-controlled GitHub repository.
2. Create a public test repository at `TestStudent/CC`.
3. Add `Labs/Lab1/main.py` to the test repository.
4. Open **Actions > Grade student submission > Run workflow**.
5. Enter `TestStudent` and leave **Save the generated score to Firestore** unchecked.
6. Open the workflow result and download the `grading-result` artifact.

## Connect Firestore

The updater expects the multi-course portal collections:

```text
users/{firebaseUid}
enrollments/{firebaseUid}__{courseId}
```

It matches the student using `users.user_name`, then finds one approved enrollment whose `course_code` matches `config/assignment.json`.

### Repository variable

Create this GitHub Actions repository variable:

```text
Settings > Secrets and variables > Actions > Variables
FIREBASE_PROJECT_ID = your-firebase-project-id
```

### Repository secret

Generate a service-account JSON file from:

```text
Firebase Console > Project settings > Service accounts > Generate new private key
```

Create this GitHub Actions repository secret and paste the complete JSON content:

```text
Settings > Secrets and variables > Actions > Secrets
FIREBASE_SERVICE_ACCOUNT
```

Never commit the JSON file.

Run the workflow again and enable **Save the generated score to Firestore**.

## Local validation

Install dependencies and verify JavaScript syntax:

```bash
npm install
npm run check
```

Generate `package-lock.json` before pushing so GitHub Actions can use `npm ci`:

```bash
npm install
git add package-lock.json
```

## Private student repositories

This starter clones public repositories. Your personal collaborator access is not automatically inherited by a workflow's `GITHUB_TOKEN`.

For private submissions, use a GitHub App with read-only repository access or keep repositories inside an instructor-controlled organization. Do not place a broadly scoped personal access token in a job that executes student code.

## Production warning

The example test executes Python on an ephemeral GitHub-hosted runner with a timeout, but it is still a starter. For stronger isolation, run submissions in a restricted container with no network, limited CPU/memory/processes and no mounted credentials.
