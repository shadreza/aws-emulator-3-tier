// Same origin as the page: CloudFront sends /api/* to the HTTP API.
const list = document.getElementById("notes");
const status = document.getElementById("status");

async function load() {
  const res = await fetch("api/notes");
  if (!res.ok) { status.textContent = `Could not load notes (${res.status})`; return; }
  const { notes } = await res.json();
  list.replaceChildren(...notes.map(n => {
    const li = document.createElement("li");
    li.textContent = n.body;
    const time = document.createElement("time");
    time.textContent = n.created_at.slice(0, 19);
    li.append(time);
    return li;
  }));
  status.textContent = notes.length ? "" : "No notes yet.";
}

document.getElementById("add").addEventListener("submit", async e => {
  e.preventDefault();
  const input = document.getElementById("text");
  const res = await fetch("api/notes", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ body: input.value }),
  });
  if (!res.ok) { status.textContent = `Could not save (${res.status})`; return; }
  input.value = "";
  load();
});

load();
