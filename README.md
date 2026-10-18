# CloudReport Community — deploy

![CloudReport Community](docs/images/cloudreport-community-hero.png)

Este repositório contém somente os arquivos necessários para instalar e atualizar o **CloudReport Community** com Docker Compose. O instalador interativo gera os segredos, monta a configuração e aguarda a aplicação ficar pronta.

> A edição Community pode ser usada gratuitamente para estudo, desenvolvimento e uso comercial por uma equipe de **uma pessoa**. Ela não permite criar outros usuários nem compartilhar projetos. Não há suporte técnico gratuito.

[English version](README.en.md) · [Termos de Uso](TERMS-OF-USE.md) · [Política de Privacidade](PRIVACY-POLICY.md)

## Arquitetura

![Arquitetura do deploy](docs/images/deployment-architecture.svg)

O instalador permite combinar:

| Componente | Opção gerenciada pelo instalador | Opção externa |
| --- | --- | --- |
| Banco de dados | PostgreSQL 17 em container, com credenciais aleatórias | PostgreSQL existente, com host, porta, banco, usuário, senha e TLS |
| Arquivos | volume Docker persistente em `/data/storage` | MinIO existente, com endpoint, credenciais, bucket e TLS |

O PostgreSQL integrado não publica sua porta no host. Somente a porta HTTP escolhida para o CloudReport é publicada. Identidade da instalação e chaves criptográficas permanecem no volume `cloudreport-data`, inclusive quando banco e MinIO são externos.

## Requisitos

- Linux com acesso administrativo (`root` ou `sudo`);
- Docker Engine 24 ou mais recente;
- Docker Compose v2 (`docker compose`);
- `curl`;
- 2 GB de RAM disponíveis; 4 GB recomendados;
- domínio e proxy HTTPS para uso público.

Para PostgreSQL externo, crie previamente um banco vazio e conceda ao usuário permissão para criar e alterar o esquema. Para MinIO externo, o endpoint deve ser alcançável pelo container e pelos navegadores que abrirão URLs assinadas.

## Instalação

Baixe e execute o instalador:

```bash
curl -fsSLo install.sh https://raw.githubusercontent.com/rovannlinhalis/linhalis-cloudreport-deploy/main/install.sh
sudo bash install.sh
```

Ao executar a partir de um clone deste repositório, basta usar:

```bash
sudo bash install.sh
```

O assistente solicita:

1. diretório de instalação, URL pública, IP de publicação e porta;
2. PostgreSQL integrado ou externo;
3. volume local ou MinIO externo;
4. imagem Docker e confirmação final.

No PostgreSQL integrado, a senha é gerada automaticamente. A chave JWT também é sempre gerada pelo instalador. O resultado padrão fica em `/opt/cloudreport`:

```text
/opt/cloudreport/
├── .env                 # configuração e segredos, permissão 600
├── docker-compose.yml
├── install-report.txt   # relatório com credenciais, permissão 600
├── install.sh
└── update.sh
```

O script valida o Compose, baixa as imagens, inicia o PostgreSQL quando selecionado, aguarda o banco e só conclui depois que `/api/bootstrap` responde com sucesso.

## Primeiro acesso

Abra a URL informada no instalador. O assistente web solicitará:

- nome, e-mail e organização opcional do responsável pelo registro;
- aceite dos Termos de Uso e da Política de Privacidade;
- criação do administrador local após a licença Community ser ativada.

Faça o primeiro acesso imediatamente e mantenha a porta restrita à sua rede até concluir o cadastro. Em uma instalação vazia, a primeira pessoa que concluir essa etapa se torna administradora.

Os dados do responsável e o identificador técnico da instalação são enviados à Linhalis para emitir e manter o contrato gratuito. A senha do administrador, usuários locais, projetos, fontes de dados, relatórios e arquivos permanecem na sua instalação.

## Atualização

O atualizador baixa o Compose mais recente, preserva `.env` e volumes, força a recriação do container da aplicação e confirma que o bootstrap voltou a responder:

```bash
cd /opt/cloudreport
sudo ./update.sh
```

Para fixar uma versão:

```bash
sudo CLOUDREPORT_INSTALL_VERSION=1.2.3 ./update.sh
```

## Operação

```bash
cd /opt/cloudreport
docker compose ps
docker compose logs -f cloudreport
docker compose down
```

`docker compose down` preserva os volumes. `docker compose down -v` apaga o PostgreSQL integrado, os arquivos locais, as chaves e a identidade da instalação. Não o utilize sem backup válido. Banco e MinIO externos não são apagados pelo Compose.

## Backup

Com PostgreSQL integrado:

```bash
cd /opt/cloudreport
docker compose exec -T postgres pg_dump -U cloudreport -d cloudreport -Fc > cloudreport.dump
```

Faça também backup do volume `cloudreport-data`, pois ele contém identidade, chaves e, no modo local, os arquivos. O volume `postgres-data` contém o banco integrado. Se usar PostgreSQL ou MinIO externos, inclua-os na política de backup da sua infraestrutura.

## Configuração manual

O caminho recomendado é `install.sh`. Para automação própria, copie `.env.example` para `.env`, substitua todos os valores `CHANGE_ME` e valide antes de iniciar:

```bash
docker compose config --quiet
docker compose pull
docker compose up -d
```

Use `COMPOSE_PROFILES=database` somente para habilitar o PostgreSQL integrado. Com banco externo, deixe `COMPOSE_PROFILES` vazio.

## HTTPS

Use Caddy, Traefik, Nginx ou o proxy da sua plataforma. Encaminhe o domínio público para `http://IP_DE_BIND:APP_PORT`, preserve `Host`, `X-Forwarded-For` e `X-Forwarded-Proto` e aceite uploads compatíveis com o tamanho dos relatórios.

## Limites e planos

Community é individual: um administrador, um projeto e até dez relatórios. Novos usuários e compartilhamento de projetos são bloqueados na API e na interface. Para planos com mais usuários ou capacidade, acesse [linhalis.com](https://linhalis.com/) ou fale pelo [WhatsApp](https://wa.me/5527998375077).

## Suporte

A licença Community não inclui suporte gratuito, SLA, consultoria, implantação ou recuperação de dados. Serviços profissionais podem ser contratados separadamente pelos canais da Linhalis.
