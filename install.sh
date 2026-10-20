#!/usr/bin/env bash
set -Eeuo pipefail

PRODUCT_NAME="CloudReport"
COMPOSE_PROJECT_NAME="cloudreport"
DEFAULT_INSTALL_DIR="/opt/cloudreport"
DEFAULT_IMAGE="${CLOUDREPORT_IMAGE:-docker.io/rovann/cloudreport:${CLOUDREPORT_INSTALL_VERSION:-latest}}"
RAW_BASE_URL="${CLOUDREPORT_INSTALL_BASE_URL:-https://raw.githubusercontent.com/rovannlinhalis/linhalis-cloudreport-deploy/main}"
ORIGINAL_WORKING_DIR="$(pwd -P)"
OPERATION="${CLOUDREPORT_OPERATION:-}"

for argument in "$@"; do
    case "$argument" in
        --install) OPERATION="install" ;;
        --update) OPERATION="update" ;;
        *) echo "Argumento desconhecido: $argument" >&2; exit 1 ;;
    esac
done

if [[ "${EUID}" -ne 0 ]]; then
    if command -v sudo >/dev/null 2>&1 && [[ -f "$0" ]]; then
        exec sudo --preserve-env=CLOUDREPORT_INSTALL_VERSION,CLOUDREPORT_IMAGE,CLOUDREPORT_INSTALL_BASE_URL,CLOUDREPORT_INSTALL_DIR,CLOUDREPORT_OPERATION bash "$0" "$@"
    fi
    echo "Execute este instalador como root (por exemplo: sudo bash install.sh)." >&2
    exit 1
fi

umask 077
if [[ -t 0 && -r /dev/tty ]]; then
    exec 3</dev/tty
else
    exec 3<&0
fi

info() { printf '\n\033[1;34m%s\033[0m\n' "$*"; }
success() { printf '\033[1;32m%s\033[0m\n' "$*"; }
fatal() { printf '\033[1;31mErro: %s\033[0m\n' "$*" >&2; exit 1; }

print_banner() {
    printf '\033[1;32m'
    cat <<'EOF'
                  .-~~~~~~~~~-.
              .-~               ~-.
             (      .-----.        )
              `-._  '-----'    _.-'
                  `----------'
                   __________
                  / ______  /|
                 / /_____/ / |
                /_________/  |
                |  _____  |  |
                | |_____| |  /
                |_________| /
                |_________|/

   ____ _                 _ ____                       _
  / ___| | ___  _   _  __| |  _ \ ___ _ __   ___  _ __| |_
 | |   | |/ _ \| | | |/ _` | |_) / _ \ '_ \ / _ \| '__| __|
 | |___| | (_) | |_| | (_| |  _ <  __/ |_) | (_) | |  | |_
  \____|_|\___/ \__,_|\__,_|_| \_\___| .__/ \___/|_|   \__|
                                      |_|
EOF
    printf '\033[0;37m                              powered by linhalis.com\033[0m\n\n'
}

prompt() {
    local variable_name="$1" label="$2" default_value="${3:-}" value
    if [[ -n "$default_value" ]]; then
        printf '%s [%s]: ' "$label" "$default_value"
    else
        printf '%s: ' "$label"
    fi
    IFS= read -r value <&3 || true
    printf -v "$variable_name" '%s' "${value:-$default_value}"
}

prompt_secret() {
    local variable_name="$1" label="$2" value
    printf '%s: ' "$label"
    IFS= read -r -s value <&3 || true
    printf '\n'
    printf -v "$variable_name" '%s' "$value"
}

confirm() {
    local label="$1" default_answer="${2:-s}" answer suffix
    [[ "$default_answer" == "s" ]] && suffix="S/n" || suffix="s/N"
    printf '%s [%s]: ' "$label" "$suffix"
    IFS= read -r answer <&3 || true
    answer="${answer:-$default_answer}"
    [[ "$answer" =~ ^[sSyY]$ ]]
}

choose_operation() {
    local default_choice="1" choice
    if [[ -s "$ORIGINAL_WORKING_DIR/.env" && -f "$ORIGINAL_WORKING_DIR/docker-compose.yml" ]] \
        || [[ -s "$DEFAULT_INSTALL_DIR/.env" && -f "$DEFAULT_INSTALL_DIR/docker-compose.yml" ]]; then
        default_choice="2"
    fi
    printf '  1) Instalar uma nova instancia\n'
    printf '  2) Atualizar uma instancia existente, preservando configuracoes e dados\n\n'
    printf 'Escolha a operacao [%s]: ' "$default_choice"
    IFS= read -r choice <&3 || true
    choice="${choice:-$default_choice}"
    case "$choice" in
        1) OPERATION="install" ;;
        2) OPERATION="update" ;;
        *) fatal "Opcao invalida." ;;
    esac
}

detect_server_ipv4() {
    local detected=""
    if command -v ip >/dev/null 2>&1; then
        detected="$(ip -4 route get 1.1.1.1 2>/dev/null | sed -n 's/.* src \([0-9.]\+\).*/\1/p' | head -n 1 || true)"
    fi
    if [[ -z "$detected" ]] && command -v hostname >/dev/null 2>&1; then
        detected="$(hostname -I 2>/dev/null | tr ' ' '\n' | grep -E '^[0-9]+(\.[0-9]+){3}$' | grep -v '^127\.' | head -n 1 || true)"
    fi
    printf '%s' "${detected:-127.0.0.1}"
}

random_secret() {
    if command -v openssl >/dev/null 2>&1; then
        openssl rand -hex 32
    else
        od -An -N32 -tx1 /dev/urandom | tr -d ' \n'
    fi
}

random_jwt_key() {
    if command -v openssl >/dev/null 2>&1; then
        openssl rand -base64 48 | tr -d '\r\n'
    else
        od -An -N48 -tx1 /dev/urandom | tr -d ' \n'
    fi
}

dotenv_quote() {
    local value="$1"
    [[ "$value" != *$'\n'* && "$value" != *$'\r'* ]] || fatal "Valores nao podem conter quebras de linha."
    value="${value//\'/\\\'}"
    printf "'%s'" "$value"
}

write_env() {
    local key="$1" value="$2"
    printf '%s=%s\n' "$key" "$(dotenv_quote "$value")" >> "$ENV_FILE"
}

replace_env() {
    local key="$1" value="$2" temporary_file
    temporary_file="$(mktemp "${INSTALL_DIR}/.env.update.XXXXXX")"
    { grep -v -E "^${key}=" "$ENV_FILE" || true; } > "$temporary_file"
    printf '%s=%s\n' "$key" "$(dotenv_quote "$value")" >> "$temporary_file"
    mv "$temporary_file" "$ENV_FILE"
    chmod 600 "$ENV_FILE"
}

connection_string_quote() {
    local value="$1"
    value="${value//\"/\"\"}"
    printf '"%s"' "$value"
}

validate_port() {
    local value="$1"
    [[ "$value" =~ ^[0-9]+$ ]] && (( value >= 1 && value <= 65535 )) \
        || fatal "Porta invalida: $value"
}

validate_public_url() {
    [[ "$1" =~ ^https?://[^/[:space:]]+/?$ ]] \
        || fatal "A URL publica deve usar http:// ou https:// e nao pode conter caminho."
}

ensure_download_tool() {
    command -v curl >/dev/null 2>&1 && return
    fatal "curl nao foi encontrado. Instale o curl e execute novamente."
}

ensure_docker() {
    if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
        return
    fi

    confirm "Docker Engine/Compose nao encontrado. Instalar pelo instalador oficial do Docker?" "s" \
        || fatal "Docker Engine com o plugin Compose e obrigatorio."
    ensure_download_tool
    local docker_installer
    docker_installer="$(mktemp)"
    curl --fail --silent --show-error --location https://get.docker.com --output "$docker_installer"
    sh "$docker_installer"
    rm -f "$docker_installer"
    if command -v systemctl >/dev/null 2>&1; then
        systemctl enable --now docker
    fi
    docker compose version >/dev/null 2>&1 || fatal "O plugin docker compose nao ficou disponivel."
}

acquire_file() {
    local relative_path="$1" target_path="$2" local_source
    local_source="${SCRIPT_DIR}/${relative_path}"
    mkdir -p "$(dirname "$target_path")"
    if [[ -f "$local_source" ]]; then
        if [[ "$(readlink -f "$local_source")" != "$(readlink -m "$target_path")" ]]; then
            install -m 600 "$local_source" "$target_path"
        fi
    else
        ensure_download_tool
        curl --fail --silent --show-error --location "${RAW_BASE_URL}/${relative_path}" --output "$target_path"
        chmod 600 "$target_path"
    fi
}

acquire_deploy_files() {
    acquire_file "docker-compose.yml" "${INSTALL_DIR}/docker-compose.yml"
    acquire_file "install.sh" "${INSTALL_DIR}/install.sh"
    acquire_file "update.sh" "${INSTALL_DIR}/update.sh"
    chmod 755 "${INSTALL_DIR}/install.sh" "${INSTALL_DIR}/update.sh"
}

prepare_instance_identity() {
    local identity_dir identity_file previous_container temporary_identity project_name volume_name volume_mount
    identity_dir="$(read_env_value INSTANCE_IDENTITY_DIR "${INSTALL_DIR}/state/instance")"
    [[ "$identity_dir" == /* ]] || identity_dir="${INSTALL_DIR}/${identity_dir#./}"
    identity_file="${identity_dir}/identity.key"
    mkdir -p "$identity_dir"
    chmod 700 "$identity_dir"

    if [[ ! -s "$identity_file" && -f "${INSTALL_DIR}/docker-compose.yml" ]]; then
        previous_container="$(cd "$INSTALL_DIR" && docker compose ps -aq cloudreport 2>/dev/null | head -n 1 || true)"
        if [[ -n "$previous_container" ]]; then
            temporary_identity="$(mktemp "${INSTALL_DIR}/.identity.XXXXXX")"
            if docker cp "${previous_container}:/data/instance/identity.key" "$temporary_identity" >/dev/null 2>&1 \
                && [[ -s "$temporary_identity" ]]; then
                install -m 600 "$temporary_identity" "$identity_file"
                printf 'Identidade existente migrada do container %s.\n' "${previous_container:0:12}"
            fi
            rm -f "$temporary_identity"
        fi
    fi

    if [[ ! -s "$identity_file" ]]; then
        project_name="$(read_env_value COMPOSE_PROJECT_NAME "$COMPOSE_PROJECT_NAME")"
        for volume_name in "${project_name}_cloudreport-data" "cloudreport_cloudreport-data" "cloudreport-community_cloudreport-data"; do
            volume_mount="$(docker volume inspect --format '{{.Mountpoint}}' "$volume_name" 2>/dev/null || true)"
            if [[ -n "$volume_mount" && -s "${volume_mount}/instance/identity.key" ]]; then
                install -m 600 "${volume_mount}/instance/identity.key" "$identity_file"
                printf 'Identidade existente migrada do volume %s.\n' "$volume_name"
                break
            fi
        done
    fi

    if [[ -s "$identity_file" ]]; then
        chmod 600 "$identity_file"
    fi
    INSTANCE_IDENTITY_DIR="$identity_dir"
}

read_env_value() {
    local key="$1" default_value="${2:-}" line value
    line="$(grep -E "^${key}=" "$ENV_FILE" | tail -n 1 || true)"
    [[ -n "$line" ]] || { printf '%s' "$default_value"; return; }
    value="${line#*=}"
    if [[ "$value" == \'*\' && "$value" == *\' ]]; then
        value="${value#\'}"
        value="${value%\'}"
    elif [[ "$value" == \"*\" && "$value" == *\" ]]; then
        value="${value#\"}"
        value="${value%\"}"
    fi
    printf '%s' "$value"
}

wait_for_postgres() {
    local database_user database_name
    database_user="$(read_env_value POSTGRES_USER cloudreport)"
    database_name="$(read_env_value POSTGRES_DB cloudreport)"
    info "Aguardando o PostgreSQL integrado"
    for _ in $(seq 1 60); do
        docker compose exec -T postgres pg_isready -U "$database_user" -d "$database_name" >/dev/null 2>&1 && return 0
        sleep 2
    done
    docker compose logs --tail=80 postgres
    fatal "O PostgreSQL integrado nao ficou pronto."
}

wait_for_api() {
    local bind_ip app_port health_host health_url status deadline attempt
    bind_ip="$(read_env_value APP_BIND_IP 0.0.0.0)"
    app_port="$(read_env_value APP_PORT 8080)"
    health_host="$bind_ip"
    case "$health_host" in
        ""|"0.0.0.0"|"::") health_host="127.0.0.1" ;;
    esac
    if [[ "$health_host" == *:* ]]; then
        health_url="http://[${health_host}]:${app_port}/api/bootstrap"
    else
        health_url="http://${health_host}:${app_port}/api/bootstrap"
    fi

    info "Aguardando as migrations e a inicializacao do CloudReport"
    deadline=$((SECONDS + 240))
    attempt=0
    status="sem resposta"
    while (( SECONDS < deadline )); do
        attempt=$((attempt + 1))
        status="$(curl --silent --show-error --connect-timeout 2 --max-time 5 \
            --output /dev/null --write-out '%{http_code}' "$health_url" 2>/dev/null || true)"
        [[ "$status" == "200" ]] && return 0
        if (( attempt % 10 == 0 )); then
            printf 'Ainda aguardando %s (HTTP %s)...\n' "$health_url" "${status:-sem resposta}"
        fi
        sleep 2
    done

    docker compose ps
    docker compose logs --tail=100 cloudreport
    fatal "O CloudReport nao ficou pronto em ${health_url} (ultimo HTTP: ${status:-sem resposta})."
}

update_installation() {
    local database_mode requested_image previous_container previous_image current_container current_image
    [[ -s "$ENV_FILE" && -f "${INSTALL_DIR}/docker-compose.yml" ]] \
        || fatal "Nenhuma instalacao foi encontrada em ${INSTALL_DIR}."

    info "Atualizando a instancia em ${INSTALL_DIR}"
    prepare_instance_identity
    replace_env "INSTANCE_IDENTITY_DIR" "$INSTANCE_IDENTITY_DIR"
    acquire_deploy_files

    requested_image=""
    if [[ -n "${CLOUDREPORT_IMAGE:-}" ]]; then
        requested_image="$CLOUDREPORT_IMAGE"
    elif [[ -n "${CLOUDREPORT_INSTALL_VERSION:-}" ]]; then
        requested_image="docker.io/rovann/cloudreport:${CLOUDREPORT_INSTALL_VERSION}"
    fi
    if [[ -n "$requested_image" ]]; then
        replace_env "CLOUDREPORT_IMAGE" "$requested_image"
        printf 'Imagem solicitada: %s\n' "$requested_image"
    fi

    (
        cd "$INSTALL_DIR"
        docker compose config --quiet
        database_mode="$(read_env_value DATABASE_MODE external)"
        if [[ "$database_mode" == "integrated" ]]; then
            docker compose up -d postgres
            wait_for_postgres
        fi

        previous_container="$(docker compose ps -q cloudreport 2>/dev/null || true)"
        previous_image=""
        if [[ -n "$previous_container" ]]; then
            previous_image="$(docker inspect --format '{{.Image}}' "$previous_container" 2>/dev/null || true)"
            printf 'Container atual: %s\n' "${previous_container:0:12}"
        fi

        docker compose pull
        info "Recriando o container da aplicacao"
        docker compose up -d --no-deps --force-recreate cloudreport
        docker compose up -d --remove-orphans

        current_container="$(docker compose ps -q cloudreport 2>/dev/null || true)"
        [[ -n "$current_container" ]] || fatal "O Compose nao criou o container cloudreport."
        current_image="$(docker inspect --format '{{.Image}}' "$current_container" 2>/dev/null || true)"
        if [[ -n "$previous_container" && "$current_container" == "$previous_container" ]]; then
            fatal "O container cloudreport nao foi recriado apesar de --force-recreate."
        fi
        printf 'Novo container: %s\n' "${current_container:0:12}"
        if [[ -n "$previous_image" && "$previous_image" == "$current_image" ]]; then
            printf '\033[1;33mAviso: o registry retornou o mesmo digest; o container foi recriado, mas a imagem publicada nao mudou.\033[0m\n'
        else
            printf 'Imagem anterior: %s\nImagem atual:    %s\n' "${previous_image:-nenhuma}" "${current_image:-desconhecida}"
        fi

        wait_for_api
    )
    success "Atualizacao concluida. Configuracoes, volumes, identidade e dados foram preservados."
}

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

print_banner
printf '%s - instalacao autogerenciada via Docker\n' "$PRODUCT_NAME"
printf 'Relatorios profissionais com dados mantidos na sua infraestrutura.\n\n'

[[ -n "$OPERATION" ]] || choose_operation
[[ "$OPERATION" == "install" || "$OPERATION" == "update" ]] || fatal "Operacao invalida: ${OPERATION}."

if [[ -n "${CLOUDREPORT_INSTALL_DIR:-}" ]]; then
    INSTALL_DIR="$CLOUDREPORT_INSTALL_DIR"
elif [[ "$OPERATION" == "update" && -s "$ORIGINAL_WORKING_DIR/.env" && -f "$ORIGINAL_WORKING_DIR/docker-compose.yml" ]]; then
    INSTALL_DIR="$ORIGINAL_WORKING_DIR"
elif [[ "$OPERATION" == "update" && -s "$DEFAULT_INSTALL_DIR/.env" && -f "$DEFAULT_INSTALL_DIR/docker-compose.yml" ]]; then
    INSTALL_DIR="$DEFAULT_INSTALL_DIR"
else
    prompt INSTALL_DIR "Diretorio de instalacao" "$DEFAULT_INSTALL_DIR"
fi
[[ "$INSTALL_DIR" == /* ]] || fatal "Use um caminho absoluto para o diretorio de instalacao."
ENV_FILE="${INSTALL_DIR}/.env"
REPORT_FILE="${INSTALL_DIR}/install-report.txt"

ensure_docker
ensure_download_tool

if [[ "$OPERATION" == "update" ]]; then
    update_installation
    exit 0
fi

[[ ! -s "$ENV_FILE" ]] || fatal "Ja existe uma instalacao em ${INSTALL_DIR}. Execute novamente e escolha Atualizar."
mkdir -p "$INSTALL_DIR"
chmod 755 "$INSTALL_DIR"
prepare_instance_identity

info "Acesso ao CloudReport"
DETECTED_SERVER_IP="$(detect_server_ipv4)"
while :; do
    prompt PUBLIC_URL "URL publica da aplicacao (sem barra final)" "http://${DETECTED_SERVER_IP}:8080"
    PUBLIC_URL="${PUBLIC_URL%/}"
    validate_public_url "$PUBLIC_URL" && break
done
prompt APP_BIND_IP "IP do host que publicara a aplicacao" "0.0.0.0"
[[ -n "$APP_BIND_IP" ]] || fatal "O IP de publicacao e obrigatorio."
prompt APP_PORT "Porta HTTP publicada no host" "8080"
validate_port "$APP_PORT"

info "Banco de dados"
if confirm "Subir um PostgreSQL exclusivo no Docker?" "s"; then
    DATABASE_MODE="integrated"
    COMPOSE_PROFILES="database"
    POSTGRES_HOST="postgres"
    POSTGRES_PORT="5432"
    POSTGRES_DB="cloudreport"
    POSTGRES_USER="cloudreport"
    POSTGRES_PASSWORD="$(random_secret)"
    POSTGRES_SSL_MODE="Disable"
    POSTGRES_TRUST_SERVER_CERTIFICATE="false"
    printf 'Credenciais fortes do PostgreSQL foram geradas automaticamente.\n'
else
    DATABASE_MODE="external"
    COMPOSE_PROFILES=""
    prompt POSTGRES_HOST "Host/IP do PostgreSQL externo" "postgres.exemplo.local"
    prompt POSTGRES_PORT "Porta do PostgreSQL" "5432"
    validate_port "$POSTGRES_PORT"
    prompt POSTGRES_DB "Nome do banco" "cloudreport"
    prompt POSTGRES_USER "Usuario do banco" "cloudreport"
    prompt_secret POSTGRES_PASSWORD "Senha do banco"
    [[ -n "$POSTGRES_HOST" && -n "$POSTGRES_DB" && -n "$POSTGRES_USER" && -n "$POSTGRES_PASSWORD" ]] \
        || fatal "Todos os dados do PostgreSQL externo sao obrigatorios."
    if confirm "O PostgreSQL externo exige TLS?" "s"; then
        POSTGRES_SSL_MODE="Require"
        if confirm "Confiar em certificado autoassinado do PostgreSQL?" "n"; then
            POSTGRES_TRUST_SERVER_CERTIFICATE="true"
        else
            POSTGRES_TRUST_SERVER_CERTIFICATE="false"
        fi
    else
        POSTGRES_SSL_MODE="Disable"
        POSTGRES_TRUST_SERVER_CERTIFICATE="false"
    fi
fi

info "Armazenamento de arquivos"
printf '  1) Volume local persistente do Docker\n'
printf '  2) MinIO externo\n\n'
printf 'Escolha o armazenamento [1]: '
IFS= read -r STORAGE_CHOICE <&3 || true
STORAGE_CHOICE="${STORAGE_CHOICE:-1}"

MINIO_ENDPOINT=""
MINIO_ACCESS_KEY=""
MINIO_SECRET_KEY=""
MINIO_BUCKET="cloudreport"
MINIO_USE_SSL="true"

case "$STORAGE_CHOICE" in
    1)
        STORAGE_MODE="local"
        BLOB_PROVIDER="Local"
        ;;
    2)
        STORAGE_MODE="minio"
        BLOB_PROVIDER="Minio"
        prompt MINIO_ENDPOINT "Endpoint do MinIO (host:porta, sem caminho)" "minio.exemplo.com:9000"
        case "$MINIO_ENDPOINT" in
            https://*) MINIO_ENDPOINT="${MINIO_ENDPOINT#https://}"; MINIO_USE_SSL="true" ;;
            http://*) MINIO_ENDPOINT="${MINIO_ENDPOINT#http://}"; MINIO_USE_SSL="false" ;;
        esac
        MINIO_ENDPOINT="${MINIO_ENDPOINT%/}"
        [[ -n "$MINIO_ENDPOINT" && "$MINIO_ENDPOINT" != */* ]] \
            || fatal "Informe o endpoint do MinIO sem caminho, por exemplo minio.exemplo.com:9000."
        prompt_secret MINIO_ACCESS_KEY "Access key do MinIO"
        prompt_secret MINIO_SECRET_KEY "Secret key do MinIO"
        prompt MINIO_BUCKET "Bucket" "cloudreport"
        [[ -n "$MINIO_ACCESS_KEY" && -n "$MINIO_SECRET_KEY" && -n "$MINIO_BUCKET" ]] \
            || fatal "Endpoint, credenciais e bucket do MinIO sao obrigatorios."
        if confirm "Usar HTTPS/TLS no MinIO?" "$([[ "$MINIO_USE_SSL" == "true" ]] && printf s || printf n)"; then
            MINIO_USE_SSL="true"
        else
            MINIO_USE_SSL="false"
        fi
        ;;
    *) fatal "Opcao de armazenamento invalida." ;;
esac

prompt CLOUDREPORT_IMAGE "Imagem do CloudReport" "$DEFAULT_IMAGE"
JWT_KEY="$(random_jwt_key)"
ADMIN_PASSWORD_SUGGESTION="$(random_secret)"
LICENSE_WEBHOOK_URL="https://n8n.linhalis.com/webhook/54791385-36ab-4ecf-80ef-1ec62c29f91f"

CLOUDREPORT_CONNECTION_STRING="Host=$(connection_string_quote "$POSTGRES_HOST");Port=$POSTGRES_PORT;Database=$(connection_string_quote "$POSTGRES_DB");Username=$(connection_string_quote "$POSTGRES_USER");Password=$(connection_string_quote "$POSTGRES_PASSWORD");SSL Mode=$POSTGRES_SSL_MODE;Trust Server Certificate=$POSTGRES_TRUST_SERVER_CERTIFICATE"

acquire_deploy_files

FINAL_ENV_FILE="$ENV_FILE"
TEMP_ENV="$(mktemp "${INSTALL_DIR}/.env.tmp.XXXXXX")"
ENV_FILE="$TEMP_ENV"
: > "$ENV_FILE"
write_env "COMPOSE_PROJECT_NAME" "$COMPOSE_PROJECT_NAME"
write_env "COMPOSE_PROFILES" "$COMPOSE_PROFILES"
write_env "CLOUDREPORT_IMAGE" "$CLOUDREPORT_IMAGE"
write_env "PUBLIC_URL" "$PUBLIC_URL"
write_env "APP_BIND_IP" "$APP_BIND_IP"
write_env "APP_PORT" "$APP_PORT"
write_env "INSTANCE_IDENTITY_DIR" "$INSTANCE_IDENTITY_DIR"
write_env "DATABASE_MODE" "$DATABASE_MODE"
write_env "POSTGRES_HOST" "$POSTGRES_HOST"
write_env "POSTGRES_PORT" "$POSTGRES_PORT"
write_env "POSTGRES_DB" "$POSTGRES_DB"
write_env "POSTGRES_USER" "$POSTGRES_USER"
write_env "POSTGRES_PASSWORD" "$POSTGRES_PASSWORD"
write_env "POSTGRES_SSL_MODE" "$POSTGRES_SSL_MODE"
write_env "POSTGRES_TRUST_SERVER_CERTIFICATE" "$POSTGRES_TRUST_SERVER_CERTIFICATE"
write_env "CLOUDREPORT_CONNECTION_STRING" "$CLOUDREPORT_CONNECTION_STRING"
write_env "JWT_KEY" "$JWT_KEY"
write_env "STORAGE_MODE" "$STORAGE_MODE"
write_env "BLOB_PROVIDER" "$BLOB_PROVIDER"
write_env "MINIO_ENDPOINT" "$MINIO_ENDPOINT"
write_env "MINIO_ACCESS_KEY" "$MINIO_ACCESS_KEY"
write_env "MINIO_SECRET_KEY" "$MINIO_SECRET_KEY"
write_env "MINIO_BUCKET" "$MINIO_BUCKET"
write_env "MINIO_USE_SSL" "$MINIO_USE_SSL"
write_env "LICENSE_WEBHOOK_URL" "$LICENSE_WEBHOOK_URL"
chmod 600 "$ENV_FILE"

info "Resumo da instalacao"
printf '  Imagem:         %s\n' "$CLOUDREPORT_IMAGE"
printf '  Aplicacao:      %s\n' "$PUBLIC_URL"
printf '  Porta:          %s:%s -> 8080\n' "$APP_BIND_IP" "$APP_PORT"
printf '  PostgreSQL:     %s (%s:%s/%s)\n' "$DATABASE_MODE" "$POSTGRES_HOST" "$POSTGRES_PORT" "$POSTGRES_DB"
printf '  Armazenamento:  %s\n' "$STORAGE_MODE"
if [[ "$STORAGE_MODE" == "minio" ]]; then
    printf '  MinIO:          %s/%s (TLS: %s)\n' "$MINIO_ENDPOINT" "$MINIO_BUCKET" "$MINIO_USE_SSL"
else
    printf '  Arquivos:       volume Docker %s_cloudreport-data\n' "$COMPOSE_PROJECT_NAME"
fi
printf '  Diretorio:      %s\n\n' "$INSTALL_DIR"
if ! confirm "Confirmar instalacao?" "n"; then
    rm -f "$TEMP_ENV"
    echo "Instalacao cancelada."
    exit 0
fi

mv "$TEMP_ENV" "$FINAL_ENV_FILE"
ENV_FILE="$FINAL_ENV_FILE"
chmod 600 "$ENV_FILE"

(
    cd "$INSTALL_DIR"
    docker compose config --quiet
    docker compose pull

    if [[ "$DATABASE_MODE" == "integrated" ]]; then
        docker compose up -d postgres
        wait_for_postgres
    fi

    docker compose up -d --remove-orphans
    wait_for_api
)

if [[ "$STORAGE_MODE" == "minio" ]]; then
    printf -v STORAGE_REPORT 'MinIO externo\nEndpoint: %s\nBucket: %s\nAccess key: %s\nSecret key: %s\nTLS: %s' \
        "$MINIO_ENDPOINT" "$MINIO_BUCKET" "$MINIO_ACCESS_KEY" "$MINIO_SECRET_KEY" "$MINIO_USE_SSL"
else
    STORAGE_REPORT="Volume local persistente: ${COMPOSE_PROJECT_NAME}_cloudreport-data (/data/storage)"
fi

cat > "$REPORT_FILE" <<EOF
CloudReport - relatorio de instalacao
Gerado em: $(date --iso-8601=seconds)

Aplicacao: ${PUBLIC_URL}
Diretorio da instalacao: ${INSTALL_DIR}
Imagem: ${CLOUDREPORT_IMAGE}

PostgreSQL: ${DATABASE_MODE}
Host: ${POSTGRES_HOST}:${POSTGRES_PORT}
Banco: ${POSTGRES_DB}
Usuario: ${POSTGRES_USER}
Senha: ${POSTGRES_PASSWORD}
SSL mode: ${POSTGRES_SSL_MODE}

Armazenamento: ${STORAGE_MODE}
${STORAGE_REPORT}

Primeiro acesso:
1. Abra ${PUBLIC_URL}.
2. Informe os dados do responsavel e configure a licenca.
3. Crie o usuario administrador local.
4. Sugestao de senha: ${ADMIN_PASSWORD_SUGGESTION}
   Esta senha e apenas uma sugestao e nao foi cadastrada automaticamente.

Operacao:
  cd ${INSTALL_DIR}
  docker compose ps
  docker compose logs -f cloudreport
  ./update.sh

Segredos e configuracoes estao em ${ENV_FILE} (permissao 600).
Proteja este relatorio: ele contem credenciais de infraestrutura.
EOF
chmod 600 "$REPORT_FILE"

success "Instalacao concluida."
cat "$REPORT_FILE"
