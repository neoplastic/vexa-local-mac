#!/usr/bin/env bash
# Remove Docker leftovers that Vexa no longer needs, so old multi-GB image layers
# don't pile up after updates. Never touches non-Vexa images, images a running
# container uses, or the current stack's data volumes (vexa-v012_*).
#
#   scripts/cleanup.sh               superseded Vexa images + stopped bot containers + build cache
#   scripts/cleanup.sh --dry-run     list what would be removed and the space it frees
#   scripts/cleanup.sh --images      only images and stopped bot containers
#   scripts/cleanup.sh --build-cache only the Docker build cache
#   scripts/cleanup.sh --old-v010    only the old Vexa 0.10 stack (images AND its data volumes)
#   scripts/cleanup.sh --referenced  print the images the current setup uses, then exit
#
# The same rules are implemented in app/Sources/VexaCore/DockerStorage.swift for
# the app's Storage page; keep the two in step.
. "$(dirname "$0")/lib.sh"

# Built by setup.sh; must match the tags used there.
JOIN_ENV_IMAGE="vexa/meet-join-env:dev"

usage() { sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'; }

dry=0; do_images=0; do_cache=0; do_old=0; referenced_only=0
for arg in "$@"; do
  case "$arg" in
    -n|--dry-run)  dry=1 ;;
    --images)      do_images=1 ;;
    --build-cache) do_cache=1 ;;
    --old-v010)    do_old=1 ;;
    --referenced)  referenced_only=1 ;;
    -h|--help)     usage; exit 0 ;;
    *)             die "Unknown option: $arg (see --help)" ;;
  esac
done
if [ $do_images = 0 ] && [ $do_cache = 0 ] && [ $do_old = 0 ]; then do_images=1; do_cache=1; fi

# Every image the current .env + compose file (all profiles) and the bot use.
referenced_images() {
  [ -f "$ROOT/.env" ] && [ -f "$COMPOSE_DIR/docker-compose.yml" ] || return 1
  load_env
  compose --profile '*' config --images || return 1
  echo "$BOT_IMAGE_LOCAL"
  echo "$JOIN_ENV_IMAGE"
  if [ -n "${BROWSER_IMAGE:-}" ]; then echo "$BROWSER_IMAGE"; fi
}

if [ $referenced_only = 1 ]; then
  referenced_images | sort -u
  exit 0
fi

docker info >/dev/null 2>&1 || die "Docker isn't reachable at $DOCKER_HOST (is Colima running?). Nothing was removed."

work="$(mktemp -d "$RUN_DIR/cleanup.XXXXXX")"
trap 'rm -rf "$work"' EXIT

if [ $do_images = 1 ] || [ $do_old = 1 ]; then
  if referenced_images > "$work/referenced" 2> "$work/referenced.err"; then
    have_refs=1
  else
    have_refs=0
    if [ $do_images = 1 ]; then
      cat "$work/referenced.err" >&2
      die "Couldn't list the images the current setup uses (no .env or compose file?). Nothing was removed."
    fi
  fi
else
  have_refs=0
  : > "$work/referenced"
fi

docker system df -v --format '{{json .}}' > "$work/df.json"
ids="$(docker ps -aq)"
if [ -n "$ids" ]; then
  # shellcheck disable=SC2086
  docker inspect --format '{"name":{{json .Name}},"image":{{json .Image}},"ref":{{json .Config.Image}},"state":{{json .State.Status}},"project":{{json (index .Config.Labels "com.docker.compose.project")}}}' $ids > "$work/containers.jsonl"
else
  : > "$work/containers.jsonl"
fi

# Decide what to remove. Prints tab-separated lines:
#   container NAME STATE | image REF LABEL SIZE UNIQUE SECTION | volume NAME SIZE | cache - SIZE | note TEXT
python3 - "$work/df.json" "$work/containers.jsonl" "$work/referenced" "$have_refs" "$do_images" "$do_cache" "$do_old" \
  > "$work/plan" <<'PY'
import json, re, sys
df_path, containers_path, refs_path, have_refs, do_images, do_cache, do_old = sys.argv[1:8]
have_refs, do_images, do_cache, do_old = (x == "1" for x in (have_refs, do_images, do_cache, do_old))
df = json.load(open(df_path))
containers = [json.loads(l) for l in open(containers_path) if l.strip()]
for c in containers:
    c["name"] = c["name"].lstrip("/")
    c["running"] = c["state"] == "running"

UNITS = {"B": 1, "kB": 1e3, "KB": 1e3, "MB": 1e6, "GB": 1e9, "TB": 1e12, "PB": 1e15}
def nbytes(s):
    m = re.match(r"\s*([0-9.]+)\s*([kKMGTP]?B)", s or "")
    return int(float(m.group(1)) * UNITS[m.group(2)]) if m else 0

def normalize(ref):
    ref = ref.strip()
    for p in ("docker.io/library/", "docker.io/", "library/"):
        if ref.startswith(p): ref = ref[len(p):]
    ref = ref.split("@", 1)[0]
    if ":" not in ref.rsplit("/", 1)[-1]: ref += ":latest"
    return ref

refs, ref_digests = set(), set()
for line in open(refs_path):
    line = line.strip()
    if not line: continue
    refs.add(normalize(line))
    if "@" in line: ref_digests.add(line.split("@", 1)[1])

def is_current_repo(r): return r.startswith("vexaai/v012-") or r.startswith("vexa/")
def is_old_repo(r): return r.startswith("vexa-") and "/" not in r and not r.startswith("vexa-v012")
def repo_of(ref): return normalize(ref).rsplit(":", 1)[0]
def is_vexa_container(c):
    return c["name"].startswith("vexa-") or is_current_repo(repo_of(c["ref"])) or is_old_repo(repo_of(c["ref"]))
def is_stopped_bot(c): return c["name"].startswith("vexa-mtg-") and not c["running"]

def classify(img):
    used = [c for c in containers if c["image"] == img["ID"]]
    running = any(c["running"] for c in used)
    repo, tag = img["Repository"], img["Tag"]
    if repo == "<none>":  # owner unknown: Vexa's only if a Vexa container was made from it
        if not any(is_vexa_container(c) for c in used): return "other"
        return "in-use" if running else "unused"
    if img["ID"] in ref_digests or img["ID"].replace("sha256:", "") in ref_digests: return "in-use"
    if tag != "<none>" and normalize(f"{repo}:{tag}") in refs: return "in-use"
    current, old = is_current_repo(repo), is_old_repo(repo)
    if not (current or old): return "other"  # never touched, running or not
    if running: return "in-use"
    if current and not have_refs: return "in-use"
    if old: return "old"
    return "leftover" if repo.startswith("vexa/") and tag != "<none>" else "unused"

images = df.get("Images") or []
kinds = {}
for img in images:
    kinds[(img["ID"], img["Repository"], img["Tag"])] = classify(img)
kept_ids = {i["ID"] for i in images if kinds[(i["ID"], i["Repository"], i["Tag"])] in ("in-use", "other")}

def out(*fields): print("\t".join(str(f) for f in fields))

removed_containers = set()
def plan_images(sections, extra_removable):
    for img in images:
        kind = kinds[(img["ID"], img["Repository"], img["Tag"])]
        if kind not in sections: continue
        tagged = img["Repository"] != "<none>" and img["Tag"] != "<none>"
        if not tagged and img["ID"] in kept_ids:
            continue  # another name for an image we keep
        blockers = [c["name"] for c in containers
                    if c["image"] == img["ID"] and c["name"] not in removed_containers and not extra_removable(c)]
        label = f'{img["Repository"]}:{img["Tag"]}' if tagged else (
            f'{img["Repository"]} (untagged {img["ID"][7:19]})' if img["Repository"] != "<none>" else f'untagged {img["ID"][7:19]}')
        if blockers:
            out("note", f"Keeping {label}: used by stopped container {', '.join(blockers)}")
            continue
        out("image", f'{img["Repository"]}:{img["Tag"]}' if tagged else img["ID"], label,
            nbytes(img["Size"]), nbytes(img.get("UniqueSize")), kind)

if do_images:
    for c in containers:
        if is_stopped_bot(c):
            removed_containers.add(c["name"]); out("container", c["name"], c["state"])
    plan_images(("unused", "leftover"), lambda c: False)
    unknown = [i for i in images if i["Repository"] == "<none>" and kinds[(i["ID"], i["Repository"], i["Tag"])] == "other"]
    if unknown:
        out("note", f"Left {len(unknown)} untagged image(s) alone: nothing shows they are Vexa's ('docker image prune' removes them)")

if do_old:
    if any(c["running"] and c["project"] == "vexa" for c in containers):
        out("note", "Vexa 0.10 containers are still running; stop them first (skipped the 0.10 cleanup)")
    else:
        old_ids = {i["ID"] for i in images if kinds[(i["ID"], i["Repository"], i["Tag"])] == "old"}
        for c in containers:
            if not c["running"] and (c["project"] == "vexa" or c["image"] in old_ids) and c["name"] not in removed_containers:
                removed_containers.add(c["name"]); out("container", c["name"], c["state"])
        plan_images(("old",), lambda c: False)
        for v in df.get("Volumes") or []:
            name, labels = v["Name"], v.get("Labels") or ""
            if name.startswith("vexa-v012"): continue  # the current stack's data: never
            if name.startswith("vexa_") or name == "vexa-bot-screenshots" or "com.docker.compose.project=vexa," in labels + ",":
                out("volume", name, nbytes(v.get("Size")))

if do_cache:
    cache = sum(nbytes(b["Size"]) for b in df.get("BuildCache") or [] if b.get("Shared") != "true")
    out("cache", "-", cache)
PY

human() {  # human BYTES -> "1.2 GB" (decimal units, like Docker)
  awk -v b="$1" 'BEGIN { split("B kB MB GB TB", u, " "); i = 1
    while (b >= 1000 && i < 5) { b /= 1000; i++ }
    if (i == 1) printf "%d B", b; else if (b < 100) printf "%.1f %s", b, u[i]; else printf "%.0f %s", b, u[i] }'
}

n_containers=0; n_images=0; n_volumes=0; img_min=0; img_max=0; vol_bytes=0; cache_bytes=0
if [ $dry = 1 ]; then info "Vexa cleanup (dry run: nothing is removed)"; else info "Vexa cleanup"; fi

while IFS=$'\t' read -r kind a b c d e; do
  case "$kind" in
    container) n_containers=$((n_containers + 1)); echo "  container  $a ($b)" ;;
    image)
      n_images=$((n_images + 1)); img_max=$((img_max + c)); img_min=$((img_min + d))
      if [ "$d" -gt 0 ] && [ "$d" -lt "$c" ]; then
        echo "  image      $b  [$e]  $(human "$c") ($(human "$d") not shared)"
      else
        echo "  image      $b  [$e]  $(human "$c")"
      fi ;;
    volume) n_volumes=$((n_volumes + 1)); vol_bytes=$((vol_bytes + b)); echo "  volume     $a  $(human "$b")" ;;
    cache)  cache_bytes=$b; echo "  build cache  $(human "$b") (regenerable: the next image build just takes longer)" ;;
    note)   echo "  note: $a" ;;
  esac
done < "$work/plan"

if [ $((n_containers + n_images + n_volumes)) = 0 ] && [ "$cache_bytes" = 0 ]; then
  ok "Nothing to clean up"
  exit 0
fi

low=$((img_min + vol_bytes + cache_bytes)); high=$((img_max + vol_bytes + cache_bytes))
if [ $dry = 1 ]; then
  if [ $low = $high ]; then
    ok "Would remove $n_containers container(s), $n_images image(s), $n_volumes volume(s) and free about $(human $low)"
  else
    ok "Would remove $n_containers container(s), $n_images image(s), $n_volumes volume(s) and free $(human $low)–$(human $high)"
    echo "  (the range depends on how many layers those images share with each other)"
  fi
  exit 0
fi

disk_total() {
  docker system df --format '{{json .}}' | python3 -c '
import json, re, sys
U = {"B": 1, "kB": 1e3, "KB": 1e3, "MB": 1e6, "GB": 1e9, "TB": 1e12}
t = 0
for line in sys.stdin:
    m = re.match(r"\s*([0-9.]+)\s*([kKMGT]?B)", json.loads(line)["Size"])
    if m: t += float(m.group(1)) * U[m.group(2)]
print(int(t))'
}
before="$(disk_total)"
failed=0
while IFS=$'\t' read -r kind a b c d e; do
  case "$kind" in
    container) docker rm "$a" >/dev/null || { warn "Could not remove container $a"; failed=1; } ;;
  esac
done < "$work/plan"
while IFS=$'\t' read -r kind a b c d e; do
  case "$kind" in
    image) docker rmi "$a" >/dev/null || { warn "Could not remove image $b"; failed=1; } ;;
  esac
done < "$work/plan"
while IFS=$'\t' read -r kind a b c d e; do
  case "$kind" in
    volume) docker volume rm "$a" >/dev/null || { warn "Could not remove volume $a"; failed=1; } ;;
    cache)  docker builder prune --all --force >/dev/null || { warn "Could not clear the build cache"; failed=1; } ;;
  esac
done < "$work/plan"
after="$(disk_total)"
freed=$((before - after)); [ $freed -lt 0 ] && freed=0
if [ $failed = 0 ]; then
  ok "Removed $n_containers container(s), $n_images image(s), $n_volumes volume(s); freed $(human $freed)"
else
  warn "Cleanup finished with errors (see above); freed $(human $freed)"
  exit 1
fi
