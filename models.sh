# Sourced by the other scripts. Loads models.env; variables already set in the environment win.
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
cfg="$here/models.env"; [ -f "$cfg" ] || cfg="$here/models.env.example"   # models.env is the user's own copy
cr=$(printf '\r')
while IFS='=' read -r k v || [ -n "$k" ]; do
  k=${k%"$cr"}; v=${v%"$cr"}   # tolerate a CRLF copy of the file (Windows checkouts)
  case $k in ''|\#*) continue;; esac
  v=${v%%#*}; v=$(echo $v)   # strip trailing comment and whitespace
  [ -z "${!k+x}" ] && export "$k=$v"
done <"$cfg"
FIX_MODEL=${FIX_MODEL:-$IMPL_MODEL}
MAX_LOOPS=${MAX_LOOPS:-5}
FIX_EFFORT=${FIX_EFFORT:-${IMPL_EFFORT:-}}
REPORT_MODEL=${REPORT_MODEL:-claude-sonnet-5-5}
REPORT_EFFORT=${REPORT_EFFORT:-medium}

# effort_args <provider/model> <effort>: fills EFFORT_ARGS with "--variant <name>". "max" means the highest variant the model
# offers. An empty effort adds nothing; a model without variants, or without the requested one, is reported and skipped.
effort_args() {
  EFFORT_ARGS=(); local model=$1 want=${2:-} have pick=""
  [ -n "$want" ] || return 0
  have=$(opencode models "${model%%/*}" --verbose 2>/dev/null | node -e '
    const t = require("fs").readFileSync(0, "utf8").replace(/\u001b\[[0-9;]*m/g, ""), id = process.argv[1];
    for (const p of t.split(/\n(?=[a-z0-9-]+\/)/)) { if (p.split("\n")[0].trim() !== id) continue;
      try { console.log(Object.keys(JSON.parse(p.slice(p.indexOf("{"))).variants || {}).join(" ")); } catch (e) {} }' "$model")
  [ -n "$have" ] || { echo "effort: $model has no variants, '$want' ignored" >&2; return 0; }
  if [[ " $have " == *" $want "* ]]; then pick=$want
  elif [ "$want" = max ]; then for v in max xhigh thinking high medium low minimal none; do [[ " $have " == *" $v "* ]] && { pick=$v; break; }; done; fi
  [ -n "$pick" ] || { echo "effort: $model has no variant '$want' (it has: $have), skipped" >&2; return 0; }
  EFFORT_ARGS=(--variant "$pick"); echo "effort: $model -> $pick" >&2
}
