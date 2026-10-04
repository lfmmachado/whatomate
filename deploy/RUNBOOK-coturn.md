# Runbook — colocar o coturn no ar

Último passo pendente. Sem ele, chamadas conectam e ficam mudas: o ICE fecha, o
DTLS estoura em 15s e o Whatomate encerra a sessão. Mensagens não são afetadas.

Tudo acontece em **um lugar só**: o editor de Compose do EasyPanel. Não é
preciso mexer no firewall nem criar arquivo no servidor — ver "Por que não
precisa de mais nada", no fim.

## 1. Gerar o segredo do TURN

Na sua máquina:

```bash
openssl rand -hex 32
```

Esse valor vai em **dois pontos** do compose, e eles precisam ser idênticos:
`secret = "..."` dentro do bloco `entrypoint`, e `--static-auth-secret=...` no
serviço `coturn`. Se divergirem, o coturn recusa a alocação e a chamada continua
muda.

## 2. Atualizar o compose no painel

EasyPanel → projeto `mooviin` → serviço `whatomate` → **Source**.

Partindo de [`easypanel-compose.yml`](easypanel-compose.yml), substitua os
`${...}` pelos valores reais — os segredos que já estão no compose atual podem
ser reaproveitados de lá, e `${TURN_SECRET}` recebe o valor do passo 1.

O que muda em relação ao que está no ar:

| Antes | Depois |
|---|---|
| 41 portas UDP publicadas | nenhuma porta publicada |
| `UDP_PORT_MIN/MAX` | `RELAY_ONLY: "true"` |
| `PUBLIC_IP` com o IP | `PUBLIC_IP: ""` |
| `config.toml` montado do host | gerado pelo `entrypoint` |
| — | serviço `coturn` |

Depois **Save** e **Deploy**.

## 3. Conferir

O serviço `coturn` deve aparecer rodando ao lado de `whatomate` e
`whatomate-redis`. O aviso *"ports is used in whatomate"* some, porque o app
deixa de publicar portas.

Se o coturn reiniciar em loop, o log dele diz o motivo. O ponto não validado é a
aceitação das flags pela imagem `coturn/coturn:4.6`.

## 4. Testar a chamada

Ligue para o +55 62 98117-3298 e acompanhe:

```bash
docker logs -f $(docker ps -qf name=whatomate-whatomate) 2>&1 | grep -iE "ICE|peer connection|media"
```

**Critério de sucesso**, e é específico: os candidatos ICE precisam aparecer como
`type=relay` em vez de `type=host`, e o `Peer connection state` precisa chegar a
`connected`. Era exatamente aí que parava antes — o ICE conectava e o peer
connection ficava em `connecting` até o timeout.

## Por que não precisa de mais nada

**Firewall.** A faixa `UDP 10000-10040` já está aberta no security group
`sg-83e445e6` (default), desde a tentativa anterior. Por isso o coturn usa
`--min-port=10001 --max-port=10040` para o relay. A porta de controle 3478 não
precisa estar aberta: quem fala com ela é o app, na mesma máquina, e esse
tráfego não passa pelo security group.

**Arquivo no servidor.** O `[[calling.ice_servers]]` é lista de tabelas e não
cabe em variável de ambiente (config.go:210). Em vez de montar um arquivo do
host — que exigiria SSH para manter —, o `entrypoint` escreve o TOML dentro do
container antes de iniciar o binário. O compose vira a única fonte de verdade.

**IP privado no `ice_servers`.** O app aponta para `172.31.21.234`, não para o
IP público: a AWS não faz hairpin de tráfego da instância para o próprio IP
público. Quem anuncia o público nos candidatos de relay é o coturn, pela flag
`--external-ip`.
