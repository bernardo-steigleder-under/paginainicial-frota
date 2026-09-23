#!/usr/bin/env bash
# Aponta o Chrome desta máquina para a página inicial da Under e instala a
# extensão que entrega os favoritos para ela.
#
# Feito para rodar em todas as máquinas (Ubuntu/Debian), uma vez, como root:
#   sudo ./instalar-na-frota.sh
#
# É idempotente: reescreve os dois arquivos de policy e não toca em mais nada.
# Não instala serviço, não deixa processo rodando, não copia código — a página
# vem do cluster e a extensão se atualiza sozinha pelo updates.xml.
#
# Por que a extensão: uma página web não tem como ler os favoritos do
# navegador, por desenho do Chrome. A extensão tem a permissão `bookmarks` e
# responde SÓ para a origem da página inicial (externally_connectable no
# manifest dela) — nenhum outro site consegue pedir esses dados.
set -euo pipefail

URL="${PAGINA_URL:-https://home.devenvvs.com}"
EXTENSAO_ID="fnlggfefepgipcigjagfcafnkdamajaj"
POLICY_DIR=/etc/opt/chrome/policies/managed

if [ "$(id -u)" -ne 0 ]; then
  echo "precisa ser root: sudo $0" >&2
  exit 1
fi

mkdir -p "$POLICY_DIR"

# Home, inicialização e nova aba.
#
# BookmarkBarEnabled de propósito fora daqui: ele forçaria a barra do Chrome em
# todo site visitado, não só nesta página. A barra que aparece na página
# inicial é desenhada por ela, com os dados que a extensão entrega.
cat > "$POLICY_DIR/paginainicial.json" <<POLICY
{
  "HomepageLocation": "$URL",
  "HomepageIsNewTabPage": false,
  "ShowHomeButton": true,
  "RestoreOnStartup": 4,
  "RestoreOnStartupURLs": ["$URL"],
  "NewTabPageLocation": "$URL"
}
POLICY

# Instalação forçada da extensão, servida por nós e não pela Web Store.
#
# force_installed e não normal_installed: a extensão volta sozinha se alguém
# remover, e some do gerenciador de extensões como algo desinstalável. O
# update_url é consultado periodicamente pelo Chrome — é assim que uma versão
# nova chega às máquinas sem rodar nada nelas de novo.
cat > "$POLICY_DIR/paginainicial-extensao.json" <<POLICY
{
  "ExtensionSettings": {
    "$EXTENSAO_ID": {
      "installation_mode": "force_installed",
      "update_url": "$URL/extensao/updates.xml"
    }
  }
}
POLICY

chmod 644 "$POLICY_DIR"/paginainicial*.json

echo "policies escritas em $POLICY_DIR:"
echo "  - paginainicial.json           home, inicialização e nova aba -> $URL"
echo "  - paginainicial-extensao.json  extensão $EXTENSAO_ID (force_installed)"
echo
echo "reinicie o Chrome para aplicar. Para conferir depois, em chrome://policy."

# Policies concorrentes: duas definindo a mesma chave disputam, e qual vence
# depende da ordem em que o Chrome lê os arquivos do diretório. Numa frota isso
# viraria máquina com home diferente de máquina, sem nada nos diferenciar — por
# isso aqui a gente resolve em vez de só avisar.
#
# A remoção é cirúrgica: saem apenas as chaves de home/nova aba, e o resto do
# arquivo fica (o ManagedBookmarks do casdoor_policy.json, por exemplo, põe o
# Casdoor na barra do Chrome e não tem relação com isto). Backup ao lado antes
# de escrever.
#
# CONFLITO_MODO=avisar pula a edição e só reporta.
CONFLITO_MODO="${CONFLITO_MODO:-resolver}"
CHAVES_DE_HOME='HomepageLocation HomepageIsNewTabPage ShowHomeButton NewTabPageLocation RestoreOnStartup RestoreOnStartupURLs'

for outro in "$POLICY_DIR"/*.json; do
  case "$outro" in
    *paginainicial.json|*paginainicial-extensao.json) continue ;;
  esac
  [ -f "$outro" ] || continue
  grep -qE '"(NewTabPageLocation|HomepageLocation|RestoreOnStartup)"' "$outro" || continue

  echo
  if [ "$CONFLITO_MODO" != "resolver" ]; then
    echo "!! $outro também define home/nova aba — as duas policies disputam."
    continue
  fi

  # JSON quebrado (vírgula sobrando, comentário // no meio) não é raro nesses
  # arquivos, e aqui vale pular o arquivo em vez de interromper o script: o
  # resto do diretório ainda precisa ser olhado, e o clone ainda precisa ser
  # apagado. A checagem vem antes do backup de propósito — falhar depois do
  # `cp` deixaria um .antes-da-paginainicial de um arquivo que ninguém editou.
  if ! python3 -m json.tool "$outro" >/dev/null 2>&1; then
    echo "!! $outro não é JSON válido — não mexi nele."
    echo "   as chaves de home dele continuam disputando com as nossas."
    echo "   veja o erro com: python3 -m json.tool $outro"
    continue
  fi

  cp -a "$outro" "$outro.antes-da-paginainicial"
  CAMINHO="$outro" CHAVES="$CHAVES_DE_HOME" python3 - <<'PY'
import json, os

caminho = os.environ["CAMINHO"]
chaves = os.environ["CHAVES"].split()
with open(caminho, encoding="utf-8") as f:
    dados = json.load(f)

removidas = [k for k in chaves if k in dados]
for k in removidas:
    del dados[k]

if not dados:
    # Sobrou um objeto vazio: o arquivo inteiro era sobre home.
    os.remove(caminho)
    print(f"   {caminho} só tinha chaves de home — arquivo removido")
else:
    with open(caminho, "w", encoding="utf-8") as f:
        json.dump(dados, f, indent=2, ensure_ascii=False)
        f.write("\n")
    print(f"   chaves removidas de {os.path.basename(caminho)}: {', '.join(removidas)}")
    print(f"   o que ficou: {', '.join(dados)}")
PY
  echo "   backup em $(basename "$outro").antes-da-paginainicial"
done

# Apaga o próprio clone, para não deixar rastro na máquina de quem recebeu.
#
# LIMPAR=nao pula esta parte — útil enquanto se testa, e obrigatório se você
# estiver rodando a partir de um diretório de trabalho de verdade.
#
# A remoção é defensiva de propósito: só apaga um diretório que contenha
# exatamente o que este repositório tem, e nada além. Rodar o script de um
# lugar errado (um `sudo ~/instalar.sh` com o arquivo solto no home, por
# exemplo) não pode virar um rm -rf no home de ninguém.
LIMPAR="${LIMPAR:-sim}"

limpar_clone() {
  local dir="$1"

  case "$dir" in
    /|/home|/root|/etc|/usr|/var|/opt|/tmp|"$HOME") return 1 ;;
  esac
  [ -d "$dir/.git" ] || return 1

  # Todo arquivo presente tem de ser um dos nossos.
  local conhecido
  while IFS= read -r item; do
    case "$(basename "$item")" in
      instalar.sh|README.md|.git|.|..) ;;
      *) return 1 ;;
    esac
  done < <(find "$dir" -maxdepth 1 -mindepth 1)

  rm -rf -- "$dir"
}

if [ "$LIMPAR" = "sim" ]; then
  AQUI="$(cd "$(dirname "$0")" && pwd)"
  echo
  if limpar_clone "$AQUI"; then
    echo "clone removido: $AQUI"
  else
    echo "clone mantido em $AQUI — não parece um clone limpo do repositório."
    echo "apague à mão se quiser: rm -rf $AQUI"
  fi
fi
