# Plan: Fork `snarktank/ralph` → GitHub-issue/PR-driven + mattpocock skills

Mục tiêu: biến Ralph loop (vốn `prd.json`-driven, 1 branch, tuần tự) thành một harness
**lấy task từ GitHub issues, cô lập bằng worktree/branch, mở PR**, và dùng **bộ skill engineering
của mattpocock** làm lớp engineering — gần với `lite-harness`. Triển khai bằng Claude Code local.

---

## 0. Kiến trúc đích (một hình)

```
to-prd / to-issues (mattpocock)        ──>  GitHub Issues (PRD cha + sub-issues, label ready-for-agent)
                                                         │
                          ┌──────────────────────────────┘
                          ▼
   ralph-gh.sh loop:  chọn issue ưu tiên cao nhất, chưa blocked
                          │
              git worktree add -B agent/<n>-<slug>  (cô lập)
                          │
        agent (claude -p) implement  ──>  skill: tdd / diagnosing-bugs / domain-modeling
                          │
                   GATE 1: validate (typecheck + test)         ← backpressure
                   GATE 2: independent review (context riêng)  ← "diff-verifier"
                          │
        PASS → commit → push → gh pr create --draft → gh issue close
        FAIL → label needs-human → comment log → giữ worktree cho người xem
                          │
              hết issue ready-for-agent → <promise>COMPLETE</promise>
```

Khác biệt so với snarktank gốc: **nguồn sự thật = GitHub** (không `prd.json`), **isolation = worktree/branch**,
**đầu ra = PR**, **engineering = skill mattpocock**, **thêm reviewer độc lập**.

---

## 1. Yêu cầu trước khi bắt đầu

- `gh` CLI đã đăng nhập: `gh auth login` (scopes: repo). Kiểm tra: `gh auth status`.
- `git` ≥ 2.30 (cần `git worktree`).
- Claude Code đã cài và đăng nhập (`claude`).
- `jq` đã cài (`jq --version`).
- Một repo đích (repo bạn muốn agent code vào) đã có remote `origin` và branch `main`.
- Quyền tạo label + issue + PR trên repo đích.

> Lưu ý: script dưới đây là một **orchestrator mới, độc lập** (`ralph-gh.sh`) — bạn KHÔNG cần
> patch từng dòng `ralph.sh` gốc. Cách này sạch hơn và tránh phụ thuộc vào nội bộ script cũ.

---

## 2. Phase 1 — Fork & scaffold

1. Fork `snarktank/ralph` về tài khoản bạn, clone về máy (chỉ để tham khảo prompt/flowchart gốc).
2. Trong **repo đích**, tạo cây thư mục:

```
scripts/ralph/
  ralph-gh.sh
  prompts/
    build.md
    review.md
.claude/skills/        # nơi cài skill mattpocock (xem Phase 2)
```

3. Bỏ phần lõi không dùng của snarktank khi mang sang: **không** copy `prd.json`, `progress.txt`,
   `skills/prd/`, `skills/ralph/` (chúng sinh/đọc `prd.json` — giờ thừa).

---

## 3. Phase 2 — Cài & cấu hình mattpocock skills

1. Lấy bộ skill engineering từ `mattpocock/skills` (thư mục `skills/engineering`) và đặt vào
   `~/.claude/skills/` (global) hoặc `.claude/skills/` (per-repo). Tối thiểu cần:
   `setup-matt-pocock-skills`, `to-prd`, `to-issues`, `triage`, `tdd`, `diagnosing-bugs`, `domain-modeling`.

2. Chạy một lần trong repo đích (trong Claude Code):

   ```
   /setup-matt-pocock-skills
   ```

   Khi được hỏi, chọn:
   - **Issue tracker = GitHub** (skill sẽ gọi `gh issue create`).
   - **Triage labels** = bộ nhãn bạn dùng (xem Phase 3 để đồng bộ).
   - **Domain docs** = `docs/agents/` (CONTEXT.md + ADR).

   Skill này viết block `## Agent skills` vào `AGENTS.md`/`CLAUDE.md` để các skill khác biết
   ngữ cảnh repo. Đây là **bước nền** — thiếu nó các skill khác không biết gọi `gh`.

---

## 4. Phase 3 — Data model trên GitHub

Ánh xạ:

| snarktank/ralph (cũ)            | Bản fork (mới)                                            |
|---------------------------------|----------------------------------------------------------|
| Story trong `prd.json`          | GitHub issue (sub-issue dưới 1 issue cha = PRD)           |
| `passes: false / true`          | Issue `open` + label `ready-for-agent` / issue `closed`  |
| Priority trong JSON             | Label `P0`/`P1`/`P2`                                      |
| `progress.txt`                  | Issue/PR comments + `AGENTS.md`/`CONTEXT.md`              |
| `branchName` (1 nhánh/feature)  | 1 branch + worktree **mỗi issue**                         |
| Commit cuối story               | commit → push → `gh issue close`                          |
| `<promise>COMPLETE</promise>`   | Hết issue `ready-for-agent` open → mở draft PR            |

Tạo label (chạy 1 lần):

```bash
gh label create ready-for-agent -c "#0E8A16" -d "Agent có thể nhận" || true
gh label create needs-human     -c "#D93F0B" -d "Agent fail, cần người" || true
gh label create blocked         -c "#6A737D" -d "Đang bị chặn" || true
for p in P0 P1 P2; do gh label create "$p" -c "#5319E7" || true; done
```

Tạo backlog (trong Claude Code, thay cho khâu `prd.json`):

```
# 1) Biến hội thoại/spec thành PRD cha trên GitHub
Load the to-prd skill and publish a PRD for: <mô tả feature của bạn>

# 2) Chẻ PRD thành sub-issue độc lập theo vertical slice, gắn label ready-for-agent + priority
Load the to-issues skill and break PRD #<số issue cha> into independently-grabbable issues.
Label each with ready-for-agent and a priority (P0/P1/P2).
```

---

## 5. Phase 4 — Orchestrator: `scripts/ralph/ralph-gh.sh`

```bash
#!/usr/bin/env bash
# ralph-gh.sh — GitHub-issue/PR-driven Ralph loop + mattpocock skills
set -euo pipefail

# ---------- Config (override qua env) ----------
REPO="${REPO:-$(gh repo view --json nameWithOwner -q .nameWithOwner)}"
BASE_BRANCH="${BASE_BRANCH:-main}"
AGENT_LABEL="${AGENT_LABEL:-ready-for-agent}"
HUMAN_LABEL="${HUMAN_LABEL:-needs-human}"
BLOCKED_LABEL="${BLOCKED_LABEL:-blocked}"
WORKTREE_ROOT="${WORKTREE_ROOT:-../ralph-worktrees}"
VALIDATE_CMD="${VALIDATE_CMD:-npm run typecheck && npm test}"   # ĐỔI theo dự án của bạn
AGENT="${AGENT:-claude}"                                        # claude | codex
PROMPT_DIR="${PROMPT_DIR:-scripts/ralph/prompts}"
MAX_ITER="${1:-20}"

log() { printf '\033[1;34m[ralph]\033[0m %s\n' "$*"; }

agent_run() { # $1 = prompt file
  case "$AGENT" in
    claude) claude -p --dangerously-skip-permissions "$(cat "$1")" ;;
    codex)  codex exec --yolo - < "$1" ;;
    *) echo "AGENT không hỗ trợ: $AGENT" >&2; exit 1 ;;
  esac
}

# ---------- Chọn issue kế tiếp: open + ready-for-agent + chưa blocked, sort theo priority ----------
select_next_issue() {
  gh issue list --repo "$REPO" --state open --label "$AGENT_LABEL" \
    --json number,labels --limit 200 \
  | jq -r --arg blk "$BLOCKED_LABEL" '
      def prio(ls): (ls | map(.name)
        | if index("P0") then 0 elif index("P1") then 1
          elif index("P2") then 2 else 3 end);
      map(select(.labels | map(.name) | index($blk) | not))
      | sort_by(prio(.labels), .number)
      | (.[0].number // empty)'
}

mkdir -p "$WORKTREE_ROOT"
iter=0
while (( iter < MAX_ITER )); do
  iter=$((iter+1)); log "iteration $iter/$MAX_ITER"

  num="$(select_next_issue || true)"
  if [ -z "${num:-}" ]; then
    log "Không còn issue '$AGENT_LABEL'. <promise>COMPLETE</promise>"; break
  fi
  log "Chọn issue #$num"

  title="$(gh issue view "$num" --repo "$REPO" --json title -q .title)"
  slug="$(echo "$title" | tr '[:upper:]' '[:lower:]' \
          | sed -E 's/[^a-z0-9]+/-/g; s/^-+|-+$//g' | cut -c1-40)"
  branch="agent/${num}-${slug}"
  wt="${WORKTREE_ROOT}/wt-${num}"

  # ----- Worktree (resume nếu đã có) -----
  git fetch origin "$BASE_BRANCH" --quiet
  if [ -d "$wt" ]; then log "Resume worktree $wt"
  else git worktree add -B "$branch" "$wt" "origin/${BASE_BRANCH}"; fi

  # ----- Build prompt = template + nội dung issue -----
  issue_ctx="$(gh issue view "$num" --repo "$REPO" --comments)"
  build_prompt="$(mktemp)"
  { cat "${PROMPT_DIR}/build.md"; echo; echo "## GitHub issue #$num"; echo "$issue_ctx"; } > "$build_prompt"

  # ----- Implement trong worktree -----
  set +e; ( cd "$wt" && agent_run "$build_prompt" ); agent_rc=$?; set -e

  # ----- GATE 1: validate -----
  set +e; ( cd "$wt" && bash -c "$VALIDATE_CMD" ); gate_rc=$?; set -e

  # ----- GATE 2: reviewer độc lập (context riêng) -----
  review_rc=1
  if [ "$gate_rc" -eq 0 ]; then
    diff_file="$(mktemp)"
    ( cd "$wt" && git add -A >/dev/null 2>&1 || true; git diff "origin/${BASE_BRANCH}" ) > "$diff_file"
    review_prompt="$(mktemp)"
    { cat "${PROMPT_DIR}/review.md"; echo; echo "## ISSUE #$num"; echo "$issue_ctx";
      echo; echo "## DIFF (origin/${BASE_BRANCH} → worktree)"; echo '```diff'; cat "$diff_file"; echo '```'; } > "$review_prompt"
    verdict="$(cd "$wt" && agent_run "$review_prompt" | tr -d '\r')"
    echo "$verdict" | grep -q "REVIEW: PASS" && review_rc=0
    log "Review verdict: $(echo "$verdict" | head -1)"
  fi

  # ----- Finalize -----
  if [ "$agent_rc" -eq 0 ] && [ "$gate_rc" -eq 0 ] && [ "$review_rc" -eq 0 ]; then
    log "PASS #$num → commit/push/PR/close"
    ( cd "$wt"
      git add -A
      git commit -m "feat: resolve #$num — $title" || true
      git push -u origin "$branch"
      gh pr create --repo "$REPO" --base "$BASE_BRANCH" --head "$branch" \
        --title "Resolve #$num: $title" --body "Closes #$num" --draft 2>/dev/null \
        || gh pr edit "$branch" --repo "$REPO" >/dev/null 2>&1 || true
    )
    gh issue comment "$num" --repo "$REPO" --body "✅ Done by ralph-gh. Branch \`$branch\`, draft PR opened."
    gh issue edit "$num" --repo "$REPO" --remove-label "$AGENT_LABEL" >/dev/null 2>&1 || true
    gh issue close "$num" --repo "$REPO"
    git worktree remove "$wt" --force
  else
    log "FAIL #$num (agent=$agent_rc gate=$gate_rc review=$review_rc) → needs-human"
    gh issue edit "$num" --repo "$REPO" --add-label "$HUMAN_LABEL" --remove-label "$AGENT_LABEL" || true
    gh issue comment "$num" --repo "$REPO" \
      --body "❌ ralph-gh dừng (agent=$agent_rc, gate=$gate_rc, review=$review_rc). Xem branch \`$branch\`."
    # giữ worktree để người xem; muốn tự dọn thì: git worktree remove "$wt" --force
  fi
done
```

Cấp quyền chạy: `chmod +x scripts/ralph/ralph-gh.sh`.

> **Quyết định thiết kế đáng chú ý:** ở đây mỗi issue → 1 branch → 1 PR (vì worktree-per-issue và
> các issue đã độc lập). Nếu bạn muốn giống lite-harness kiểu **1 PR / PRD** (gom nhiều sub-issue vào
> một branch), xem Phase 7.

---

## 6. Phase 5 — Prompt templates

### `scripts/ralph/prompts/build.md`

```markdown
You are an autonomous engineer working a SINGLE GitHub issue inside a clean git worktree.

Rules:
- Use the `tdd` skill (red → green → refactor) to implement ONLY what this issue asks.
- If you hit a hard bug or perf regression, use the `diagnosing-bugs` skill.
- Keep the change to a single vertical slice. Do NOT expand scope beyond the issue.
- If the domain model changed, update CONTEXT.md / ADRs via the `domain-modeling` skill.
- Make the project's typecheck and tests pass locally before you finish.
- Commit with a conventional message that references the issue (e.g. `feat: ... (#<n>)`).
- Do NOT push, open PRs, or close the issue — the harness handles that.

The issue (body + comments) is appended below.
```

### `scripts/ralph/prompts/review.md`

```markdown
You are an INDEPENDENT reviewer. You did NOT write this code. Review the diff against the issue.

Check:
- Correctness vs the issue's acceptance criteria.
- The change is covered by tests.
- No scope creep beyond the issue.
- No obvious security / maintainability problems, no leftover debug code or secrets.

Respond with EXACTLY one of these as the FIRST line:
`REVIEW: PASS`  or  `REVIEW: FAIL`
Then a short bullet list of reasons. If anything material is wrong or untested, choose FAIL.
```

---

## 7. Phase 6 — Tùy chọn nâng cao

- **Chạy song song (kiểu Bernstein):** vì đã có worktree-per-issue, bạn có thể vét nhiều issue cùng lúc.
  Sửa loop để lấy N issue đầu rồi chạy mỗi issue trong một subshell `&`, cuối cùng `wait`. Lưu ý
  giới hạn rate limit của agent và xung đột merge khi nhiều PR cùng đụng một file.

- **1 PR / PRD (giống lite-harness):** thay vì branch-per-issue, tạo **1 branch theo issue cha (PRD)**,
  mỗi sub-issue commit vào branch đó; khi hết sub-issue của PRD thì mở **một** draft PR và chạy thêm
  một **PR-level review** trên toàn diff trước khi bỏ nhãn draft.

- **Blocked-by:** convention `Blocked by #x` trong body, hoặc đơn giản gắn label `blocked`. `select_next_issue`
  đã bỏ qua issue có label `blocked`. Muốn tự động: thêm bước kiểm tra các issue được tham chiếu
  `Blocked by #x` còn open hay không trước khi nhận.

- **Bộ nhớ bền:** sau mỗi PASS, ngoài comment lên issue, cho agent cập nhật `AGENTS.md`/`CONTEXT.md`
  (mattpocock đã làm việc này qua `domain-modeling`) — đây là thứ thay cho `progress.txt`.

---

## 8. Kiểm thử (đi từ nhỏ đến lớn)

1. **Dry-run chọn issue** (không chạy agent):
   ```bash
   REPO="owner/repo" bash -c 'source scripts/ralph/ralph-gh.sh; select_next_issue' 2>/dev/null || \
   gh issue list --label ready-for-agent --state open
   ```
2. **Một issue, một vòng:** tạo 1 issue nhỏ (vd: "thêm health-check endpoint"), gắn `ready-for-agent`,
   rồi: `MAX_ITER=1 VALIDATE_CMD="<lệnh test của bạn>" ./scripts/ralph/ralph-gh.sh 1`.
3. Kiểm tra: branch `agent/<n>-...` được push, draft PR mở, issue đóng, worktree được dọn.
4. **Vét backlog:** tạo vài issue, chạy `./scripts/ralph/ralph-gh.sh 10`.

---

## 9. Checklist triển khai

- [ ] `gh auth status` OK, `jq` có sẵn, `git worktree` chạy được.
- [ ] Repo đích có `origin` + `main`.
- [ ] Tạo đủ label: `ready-for-agent`, `needs-human`, `blocked`, `P0/P1/P2`.
- [ ] Cài skill mattpocock vào `.claude/skills/`, chạy `/setup-matt-pocock-skills` (chọn GitHub).
- [ ] Bỏ `prd.json`/`progress.txt`/`skills/prd`/`skills/ralph` khỏi bản fork.
- [ ] Tạo `scripts/ralph/ralph-gh.sh` + `prompts/build.md` + `prompts/review.md`.
- [ ] Đặt `VALIDATE_CMD` đúng lệnh test/typecheck của dự án.
- [ ] Sinh backlog bằng `to-prd` + `to-issues`.
- [ ] Test 1 issue → 1 vòng → PASS path hoạt động.
- [ ] (Tùy chọn) bật song song / PR-per-PRD / blocked-by tự động.

---

## Phụ lục — Prompt dán thẳng vào Claude Code cho từng phase

**A. Scaffold:**
```
Tạo cây thư mục scripts/ralph/ với ralph-gh.sh và prompts/{build.md,review.md} theo plan trong
ralph-gh-plan.md. Dán đúng nội dung script và 2 prompt template. chmod +x cho ralph-gh.sh.
```

**B. Setup skills:**
```
/setup-matt-pocock-skills
```
(Chọn: issue tracker = GitHub; labels = ready-for-agent, needs-human, blocked, P0/P1/P2; docs = docs/agents/)

**C. Tạo label:**
```
Chạy các lệnh gh label create cho: ready-for-agent, needs-human, blocked, P0, P1, P2 (bỏ qua nếu đã tồn tại).
```

**D. Sinh backlog:**
```
Load the to-prd skill and publish a PRD for: <mô tả feature>.
Then load the to-issues skill and break that PRD into independent vertical-slice issues,
labeling each with ready-for-agent and a priority (P0/P1/P2).
```

**E. Chạy thử 1 vòng:**
```
Chạy: MAX_ITER=1 VALIDATE_CMD="<lệnh test>" ./scripts/ralph/ralph-gh.sh 1
Rồi báo cáo: branch nào được tạo, PR nào mở, issue nào đóng, worktree có được dọn không.
```
