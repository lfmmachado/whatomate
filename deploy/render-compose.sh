#!/usr/bin/env bash
# Gera o compose com os valores já substituídos, pronto para colar no EasyPanel.
#
# O EasyPanel não alimenta a interpolação ${VAR} do compose (ela acontece na
# leitura do arquivo; a aba de ambiente dele injeta só dentro do container).
# Pior: a variável declarada vazia no compose SOBRESCREVE a do painel. Por isso
# o valor precisa ir literal no arquivo.
#
#   cp deploy/easypanel.env.example deploy/.env.local   # e preencha os segredos
#   bash deploy/render-compose.sh
#
# Saída: deploy/easypanel-compose.local.yml (ignorado pelo git).
set -euo pipefail

cd "$(dirname "$0")/.."
ENV_FILE=deploy/.env.local
TEMPLATE=deploy/easypanel-compose.yml
OUT=deploy/easypanel-compose.local.yml

[ -f "$ENV_FILE" ] || {
	echo "erro: $ENV_FILE não existe." >&2
	echo "  cp deploy/easypanel.env.example $ENV_FILE   # depois preencha" >&2
	exit 1
}

python3 - "$ENV_FILE" "$TEMPLATE" "$OUT" <<'PY'
import re, sys

env_file, template, out = sys.argv[1:4]

env = {}
for line in open(env_file):
    line = line.strip()
    if not line or line.startswith("#") or "=" not in line:
        continue
    k, v = line.split("=", 1)
    env[k.strip()] = v.strip()

text = open(template).read()
used, missing = set(), set()

def sub(m):
    name = m.group(1)
    if name == "VARIAVEIS":          # menção em comentário, não é placeholder
        return m.group(0)
    val = env.get(name, "")
    (used if val else missing).add(name)
    return val                       # cru; as aspas vêm no passo seguinte

text = re.sub(r"\$\{([A-Z0-9_]+)\}", sub, text)

# Aspas no valor inteiro das env vars (nomes em CAIXA ALTA), para que base64 com
# ":" ou "#" e senhas com caractere especial não confundam o parser YAML.
# Chaves do compose (image, ports, mode...) são minúsculas e ficam intactas.
def quote(m):
    indent, key, val = m.group(1), m.group(2), m.group(3).rstrip()
    if val == "":
        return '%s%s: ""' % (indent, key)   # vazio explícito, não YAML null
    if val.startswith(('"', "'")):
        return m.group(0)
    return '%s%s: "%s"' % (indent, key, val.replace('"', '\\"'))

text = re.sub(r'^(\s+)([A-Z][A-Z0-9_]*): (.*)$', quote, text, flags=re.M)
open(out, "w").write(text)

print("preenchidas (%d): %s" % (len(used), ", ".join(sorted(used))))
if missing:
    print("VAZIAS  (%d): %s" % (len(missing), ", ".join(sorted(missing))))
print("gerado: %s" % out)
PY

echo
echo "Placeholders não resolvidos (fora de comentários), deve ser 0:"
grep -v '^\s*#' "$OUT" | grep -c '\${' || true
