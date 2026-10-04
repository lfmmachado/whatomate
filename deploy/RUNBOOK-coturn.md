# Runbook — colocar o coturn no ar

Último passo pendente do projeto. Sem ele, chamadas conectam e ficam mudas: o
ICE fecha, o DTLS estoura em 15s e o Whatomate encerra a sessão.

Tempo estimado: 15 minutos. Nada aqui afeta mensagens, que já funcionam.

## 1. Security group da EC2 (console da AWS)

Na instância `i-0efb95cd982d8fcd1`, regras de entrada, origem `0.0.0.0/0`:

| Porta | Protocolo | Para quê |
|---|---|---|
| 3478 | TCP | controle do TURN |
| 3478 | UDP | controle do TURN |
| 49160-49200 | UDP | mídia relayada |

Não dá para restringir a origem: a mídia vem dos servidores da Meta, que não
publicam faixa fixa. A faixa antiga `10000-10040` pode ser removida.

## 2. Os dois arquivos no host

Via SSH, como root. Gera um segredo e grava nos dois lugares de uma vez — eles
precisam ser idênticos, senão o coturn recusa a alocação e a chamada continua
muda:

```bash
S=$(openssl rand -hex 32)
printf '[app]\nname = "Whatomate"\n\n[[calling.ice_servers]]\nurls = ["turn:172.31.21.234:3478"]\nsecret = "%s"\ncredential_ttl = 86400\n' "$S" > /etc/easypanel/projects/whatomate/config.toml
printf 'listening-port=3478\nfingerprint\nuse-auth-secret\nstatic-auth-secret=%s\nrealm=chat.mooviin.app\nexternal-ip=3.93.191.20/172.31.21.234\nmin-port=49160\nmax-port=49200\nno-tls\nno-dtls\nno-multicast-peers\nno-cli\nstale-nonce=600\ntotal-quota=100\nlog-file=stdout\nsimple-log\n' "$S" > /etc/easypanel/projects/whatomate/turnserver.conf
unset S
```

O endereço `172.31.21.234` é o IP **privado** da EC2, de propósito: a AWS não faz
hairpin de tráfego da instância para o próprio IP público. Quem anuncia o
público nos candidatos de relay é o coturn, pela diretiva `external-ip`.

## 3. Compose novo no EasyPanel

Na sua máquina, no repositório:

```bash
cp deploy/easypanel.env.example deploy/.env.local   # preencha os 6 segredos
bash deploy/render-compose.sh
```

Isso gera `deploy/easypanel-compose.local.yml` com os valores literais. Cole no
editor do serviço Compose do projeto `mooviin` e faça o deploy.

Se não quiser recriar o `.env.local`, dá para colar
[`easypanel-compose.yml`](easypanel-compose.yml) e substituir os `${...}` à mão
no painel — são 11 ocorrências.

O que muda em relação ao que está no ar hoje: some o bloco de 41 portas UDP
(com relay o app não precisa de porta aberta), entra o serviço `coturn` com
`network_mode: host`, `RELAY_ONLY` vira `true` e `PUBLIC_IP` fica vazio.

## 4. Conferir que subiu

No servidor:

```bash
docker ps --filter name=coturn --format '{{.Names}} | {{.Status}}'; ss -lnup | grep 3478
```

De fora:

```bash
nc -z -w 5 3.93.191.20 3478 && echo "coturn acessível"
```

Se o container reiniciar em loop, o log dele diz o porquê — o ponto mais
provável é a forma de invocação da imagem (`command: ["-c", ...]`), que não foi
validada contra a imagem real.

## 5. Teste de chamada

Ligue para o +55 62 98117-3298 e acompanhe:

```bash
docker logs -f $(docker ps -qf name=whatomate-whatomate) 2>&1 | grep -i "ICE\|peer connection\|media"
```

**O sinal de sucesso** é o tipo dos candidatos: com o relay funcionando eles
aparecem como `type=relay`, não `type=host`. E o `Peer connection state` precisa
chegar a `connected` — era aí que parava antes.

Se continuar mudo com candidatos `relay`, o problema passa a ser entre coturn e
Meta: confira o `external-ip` e a faixa 49160-49200 no security group.
