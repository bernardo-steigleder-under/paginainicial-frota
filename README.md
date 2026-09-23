# paginainicial-frota

O que roda nas máquinas para que o Chrome abra a página inicial da Under
(`https://home.devenvvs.com`) e mostre a barra de favoritos.

```bash
sudo ./instalar.sh
```

Feito para Ubuntu/Debian. É idempotente: rodar de novo reescreve os mesmos
arquivos e não estraga nada.

Ao terminar, **o script apaga o próprio clone** — a máquina fica só com as
policies, sem resquício do que foi usado para instalá-las. Numa linha:

```bash
git clone https://github.com/bernardo-steigleder-under/paginainicial-frota.git /tmp/frota && sudo /tmp/frota/instalar.sh
```

A remoção é defensiva: só apaga um diretório que seja um clone (tem `.git`) e
que contenha exatamente `instalar.sh` e `README.md` — nada além. Rodar o script
de dentro de uma pasta com outras coisas, ou de um lugar que não é clone, faz
ele recusar e avisar, em vez de apagar. `LIMPAR=nao` desliga a limpeza, que é o
que você quer enquanto estiver testando.

## O que ele faz

Escreve duas policies em `/etc/opt/chrome/policies/managed/` e sai. Não
instala serviço, não copia código, não deixa processo rodando — a página vem do
cluster e a extensão se atualiza sozinha.

| arquivo | o quê |
| --- | --- |
| `paginainicial.json` | home, páginas de inicialização e nova aba |
| `paginainicial-extensao.json` | instala a extensão de favoritos (`force_installed`) |

Depois é preciso **reiniciar o Chrome**. Para conferir, `chrome://policy`.

### Por que a extensão

Uma página web não tem como ler os favoritos do navegador — não existe API para
isso, e o arquivo do perfil está na máquina da pessoa. Servida pelo cluster, a
página depende da extensão, que responde **só** para a origem
`https://home.devenvvs.com` (limitado no `externally_connectable` do manifest
dela, não por convenção). Os favoritos não saem do navegador: a extensão os
entrega ao JavaScript da página, que desenha a barra ali mesmo.

`force_installed` significa que a pessoa não consegue removê-la e que ela volta
sozinha — e que aparece como gerenciada pela organização. É o comportamento
desejado aqui, mas vale as pessoas saberem por quê.

### Policies concorrentes

Duas policies definindo `HomepageLocation` disputam, e qual vence depende da
ordem em que o Chrome lê o diretório — numa frota, isso é home diferente de
máquina para máquina, sem nada que as diferencie. O `casdoor_policy.json`, que
já estava espalhado, aponta a home para o Casdoor.

Por isso o script **remove** as chaves de home dos outros arquivos, deixando
backup `.antes-da-paginainicial` ao lado, e preserva o resto (o
`ManagedBookmarks` daquele arquivo, por exemplo, põe o Casdoor na barra do
Chrome e não tem relação com isto). Arquivo que só tinha chaves de home é
removido inteiro.

`CONFLITO_MODO=avisar ./instalar.sh` volta a só reportar, sem editar.

⚠️ Se algum outro processo de vocês distribui esses arquivos, ele vai reescrever
as chaves na próxima execução e o conflito volta. Nesse caso, corrija na origem.

## Variáveis

| variável | padrão | para quê |
| --- | --- | --- |
| `PAGINA_URL` | `https://home.devenvvs.com` | apontar para outro host |
| `CONFLITO_MODO` | `resolver` | `avisar` não edita outras policies |

## O ID da extensão

Está fixo no script: `fnlggfefepgipcigjagfcafnkdamajaj`. Ele deriva da chave de assinatura, guardada no
Vault em `secret/homebrowser/extensao`.

Publicar uma versão nova da extensão **não** muda o ID — as máquinas pegam
sozinhas pelo `updates.xml`. O ID só muda se a chave for trocada (por perda,
por exemplo), e aí este script precisa ser atualizado e rodado de novo em todas
as máquinas.

O código da extensão e da página vive em
[home](https://github.com/bernardo-steigleder-under/home).
