export function parseFeedback(feedback) {
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
    const review = message.match(/^manual review recommended\s*-\s*(.*?)\s*\(provisional credit\)$/i);
    if (review) return { name, status: "Manual review", details: sentence(review[1]) };
    if (/^missing\s*\(0\)$/i.test(message)) return { name, status: "Missing", details: "Required file was not found." };
    return { name, status: "Failed", details: sentence(stripZero(message)) };
  });
  return { summary, checks };
}

export function statusColors(status) {
  if (status === "Passed") return { text: "#116329", background: "#dafbe1" };
  if (status === "Manual review") return { text: "#7d4e00", background: "#fff8c5" };
  if (status === "Missing") return { text: "#7d4e00", background: "#fff8c5" };
  return { text: "#a40e26", background: "#ffebe9" };
}

function stripZero(value) {
  return String(value || "").replace(/\s*\(0\)\s*$/, "").trim();
}

function sentence(value) {
  const text = String(value || "No explanation was produced.").trim();
  return `${text.charAt(0).toUpperCase()}${text.slice(1)}${/[.!?]$/.test(text) ? "" : "."}`;
}
