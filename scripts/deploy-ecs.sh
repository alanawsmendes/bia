#!/bin/bash

# Script de Deploy para ECS - Projeto BIA
# Autor: Amazon Q
# Versão: 1.0.0

set -e

# Cores para output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configurações padrão
DEFAULT_REGION="us-east-1"
DEFAULT_CLUSTER="bia-cluster-alb"
DEFAULT_SERVICE="bia-service"
DEFAULT_TASK_DEFINITION="bia-tf"
DEFAULT_ECR_REPO="bia"

# Função para exibir help
show_help() {
    echo -e "${BLUE}=== Script de Deploy ECS - Projeto BIA ===${NC}"
    echo ""
    echo -e "${YELLOW}DESCRIÇÃO:${NC}"
    echo "  Script para build, tag e deploy de aplicações no ECS com suporte a rollback"
    echo "  Cada build gera uma imagem com tag baseada no commit hash atual"
    echo ""
    echo -e "${YELLOW}USO:${NC}"
    echo "  $0 [COMANDO] [OPÇÕES]"
    echo ""
    echo -e "${YELLOW}COMANDOS:${NC}"
    echo "  build     - Faz build da imagem Docker com tag do commit"
    echo "  deploy    - Faz deploy da imagem atual para o ECS"
    echo "  rollback  - Faz rollback para uma versão anterior"
    echo "  list      - Lista as últimas 10 imagens disponíveis no ECR"
    echo "  help      - Exibe esta ajuda"
    echo ""
    echo -e "${YELLOW}OPÇÕES:${NC}"
    echo "  -r, --region REGION           Região AWS (padrão: $DEFAULT_REGION)"
    echo "  -c, --cluster CLUSTER         Nome do cluster ECS (padrão: $DEFAULT_CLUSTER)"
    echo "  -s, --service SERVICE         Nome do serviço ECS (padrão: $DEFAULT_SERVICE)"
    echo "  -t, --task-def TASK_DEF       Nome da task definition (padrão: $DEFAULT_TASK_DEFINITION)"
    echo "  -e, --ecr-repo ECR_REPO       Nome do repositório ECR (padrão: $DEFAULT_ECR_REPO)"
    echo "  -v, --version VERSION         Versão específica para rollback (formato: commit-hash)"
    echo ""
    echo -e "${YELLOW}EXEMPLOS:${NC}"
    echo "  # Build e deploy completo"
    echo "  $0 build && $0 deploy"
    echo ""
    echo "  # Deploy em região específica"
    echo "  $0 deploy --region us-west-2"
    echo ""
    echo "  # Rollback para versão específica"
    echo "  $0 rollback --version a1b2c3d4"
    echo ""
    echo "  # Listar versões disponíveis"
    echo "  $0 list"
    echo ""
    echo -e "${YELLOW}FLUXO RECOMENDADO:${NC}"
    echo "  1. $0 build     # Gera imagem com tag do commit atual"
    echo "  2. $0 deploy    # Faz deploy da nova versão"
    echo "  3. $0 rollback  # Se necessário, volta para versão anterior"
}

# Função para log com timestamp
log() {
    echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] $1${NC}"
}

# Função para log de erro
error() {
    echo -e "${RED}[ERRO] $1${NC}" >&2
}

# Função para log de warning
warning() {
    echo -e "${YELLOW}[AVISO] $1${NC}"
}

# Função para obter commit hash
get_commit_hash() {
    local hash=$(git rev-parse --short=8 HEAD 2>/dev/null)
    if [ -z "$hash" ]; then
        error "Não foi possível obter o commit hash. Certifique-se de estar em um repositório Git."
        exit 1
    fi
    echo "$hash"
}

# Função para obter account ID
get_account_id() {
    aws sts get-caller-identity --query Account --output text --region "$REGION"
}

# Função para build da imagem
build_image() {
    log "Iniciando build da imagem Docker..."
    
    local commit_hash=$(get_commit_hash)
    local account_id=$(get_account_id)
    local ecr_uri="${account_id}.dkr.ecr.${REGION}.amazonaws.com/${ECR_REPO}"
    
    log "Commit hash: $commit_hash"
    log "ECR URI: $ecr_uri"
    
    # Login no ECR
    log "Fazendo login no ECR..."
    aws ecr get-login-password --region "$REGION" | docker login --username AWS --password-stdin "$ecr_uri"
    
    # Build da imagem
    log "Executando docker build..."
    docker build -t "${ECR_REPO}:${commit_hash}" -t "${ECR_REPO}:latest" .
    
    # Tag para ECR
    docker tag "${ECR_REPO}:${commit_hash}" "${ecr_uri}:${commit_hash}"
    docker tag "${ECR_REPO}:latest" "${ecr_uri}:latest"
    
    # Push para ECR
    log "Enviando imagem para ECR..."
    docker push "${ecr_uri}:${commit_hash}"
    docker push "${ecr_uri}:latest"
    
    log "Build concluído com sucesso!"
    log "Imagem disponível: ${ecr_uri}:${commit_hash}"
}

# Função para criar nova task definition
create_task_definition() {
    local image_uri="$1"
    local commit_hash="$2"
    
    log "Criando nova task definition..."
    
    # Obter task definition atual
    local current_td=$(aws ecs describe-task-definition \
        --task-definition "$TASK_DEFINITION" \
        --region "$REGION" \
        --query 'taskDefinition' \
        --output json)
    
    if [ $? -ne 0 ]; then
        error "Não foi possível obter a task definition atual: $TASK_DEFINITION"
        exit 1
    fi
    
    # Criar nova task definition com a nova imagem
    local new_td=$(echo "$current_td" | jq --arg image "$image_uri" '
        .containerDefinitions[0].image = $image |
        del(.taskDefinitionArn, .revision, .status, .requiresAttributes, .placementConstraints, .compatibilities, .registeredAt, .registeredBy)
    ')
    
    # Registrar nova task definition
    local new_td_arn=$(echo "$new_td" | aws ecs register-task-definition \
        --region "$REGION" \
        --cli-input-json file:///dev/stdin \
        --query 'taskDefinition.taskDefinitionArn' \
        --output text)
    
    if [ $? -ne 0 ]; then
        error "Falha ao registrar nova task definition"
        exit 1
    fi
    
    log "Nova task definition criada: $new_td_arn"
    echo "$new_td_arn"
}

# Função para deploy
deploy_service() {
    log "Iniciando deploy para ECS..."
    
    local commit_hash=$(get_commit_hash)
    local account_id=$(get_account_id)
    local image_uri="${account_id}.dkr.ecr.${REGION}.amazonaws.com/${ECR_REPO}:${commit_hash}"
    
    # Verificar se a imagem existe no ECR
    aws ecr describe-images \
        --repository-name "$ECR_REPO" \
        --image-ids imageTag="$commit_hash" \
        --region "$REGION" \
        --query 'imageDetails[0].imageTags' \
        --output text > /dev/null 2>&1
    
    if [ $? -ne 0 ]; then
        error "Imagem não encontrada no ECR: $image_uri"
        error "Execute primeiro: $0 build"
        exit 1
    fi
    
    # Criar nova task definition
    local new_td_arn=$(create_task_definition "$image_uri" "$commit_hash")
    
    # Atualizar serviço
    log "Atualizando serviço ECS..."
    aws ecs update-service \
        --cluster "$CLUSTER" \
        --service "$SERVICE" \
        --task-definition "$new_td_arn" \
        --region "$REGION" \
        --query 'service.serviceName' \
        --output text > /dev/null
    
    if [ $? -ne 0 ]; then
        error "Falha ao atualizar serviço ECS"
        exit 1
    fi
    
    log "Deploy iniciado com sucesso!"
    log "Aguardando estabilização do serviço..."
    
    # Aguardar estabilização
    aws ecs wait services-stable \
        --cluster "$CLUSTER" \
        --services "$SERVICE" \
        --region "$REGION"
    
    if [ $? -eq 0 ]; then
        log "Deploy concluído com sucesso!"
        log "Versão deployada: $commit_hash"
    else
        warning "Timeout aguardando estabilização. Verifique o status do serviço manualmente."
    fi
}

# Função para listar imagens
list_images() {
    log "Listando últimas 10 imagens no ECR..."
    
    aws ecr describe-images \
        --repository-name "$ECR_REPO" \
        --region "$REGION" \
        --query 'sort_by(imageDetails,&imagePushedAt)[-10:].[join(`", "`, imageTags || [`"<no-tag>"`]),imagePushedAt]' \
        --output table
}

# Função para rollback
rollback_service() {
    if [ -z "$VERSION" ]; then
        error "Versão não especificada para rollback. Use --version ou -v"
        echo ""
        echo "Versões disponíveis:"
        list_images
        exit 1
    fi
    
    log "Iniciando rollback para versão: $VERSION"
    
    local account_id=$(get_account_id)
    local image_uri="${account_id}.dkr.ecr.${REGION}.amazonaws.com/${ECR_REPO}:${VERSION}"
    
    # Verificar se a imagem existe
    aws ecr describe-images \
        --repository-name "$ECR_REPO" \
        --image-ids imageTag="$VERSION" \
        --region "$REGION" \
        --query 'imageDetails[0].imageTags' \
        --output text > /dev/null 2>&1
    
    if [ $? -ne 0 ]; then
        error "Versão não encontrada no ECR: $VERSION"
        echo ""
        echo "Versões disponíveis:"
        list_images
        exit 1
    fi
    
    # Criar nova task definition com a imagem de rollback
    local new_td_arn=$(create_task_definition "$image_uri" "$VERSION")
    
    # Atualizar serviço
    log "Executando rollback..."
    aws ecs update-service \
        --cluster "$CLUSTER" \
        --service "$SERVICE" \
        --task-definition "$new_td_arn" \
        --region "$REGION" \
        --query 'service.serviceName' \
        --output text > /dev/null
    
    if [ $? -ne 0 ]; then
        error "Falha ao executar rollback"
        exit 1
    fi
    
    log "Rollback iniciado com sucesso!"
    log "Aguardando estabilização do serviço..."
    
    # Aguardar estabilização
    aws ecs wait services-stable \
        --cluster "$CLUSTER" \
        --services "$SERVICE" \
        --region "$REGION"
    
    if [ $? -eq 0 ]; then
        log "Rollback concluído com sucesso!"
        log "Versão atual: $VERSION"
    else
        warning "Timeout aguardando estabilização. Verifique o status do serviço manualmente."
    fi
}

# Parsing de argumentos
COMMAND=""
REGION="$DEFAULT_REGION"
CLUSTER="$DEFAULT_CLUSTER"
SERVICE="$DEFAULT_SERVICE"
TASK_DEFINITION="$DEFAULT_TASK_DEFINITION"
ECR_REPO="$DEFAULT_ECR_REPO"
VERSION=""

while [[ $# -gt 0 ]]; do
    case $1 in
        build|deploy|rollback|list|help)
            COMMAND="$1"
            shift
            ;;
        -r|--region)
            REGION="$2"
            shift 2
            ;;
        -c|--cluster)
            CLUSTER="$2"
            shift 2
            ;;
        -s|--service)
            SERVICE="$2"
            shift 2
            ;;
        -t|--task-def)
            TASK_DEFINITION="$2"
            shift 2
            ;;
        -e|--ecr-repo)
            ECR_REPO="$2"
            shift 2
            ;;
        -v|--version)
            VERSION="$2"
            shift 2
            ;;
        *)
            error "Opção desconhecida: $1"
            echo ""
            show_help
            exit 1
            ;;
    esac
done

# Verificar se comando foi especificado
if [ -z "$COMMAND" ]; then
    error "Comando não especificado"
    echo ""
    show_help
    exit 1
fi

# Verificar dependências
if ! command -v aws &> /dev/null; then
    error "AWS CLI não encontrado. Instale o AWS CLI primeiro."
    exit 1
fi

if ! command -v docker &> /dev/null; then
    error "Docker não encontrado. Instale o Docker primeiro."
    exit 1
fi

if ! command -v jq &> /dev/null; then
    error "jq não encontrado. Instale o jq primeiro."
    exit 1
fi

# Executar comando
case $COMMAND in
    build)
        build_image
        ;;
    deploy)
        deploy_service
        ;;
    rollback)
        rollback_service
        ;;
    list)
        list_images
        ;;
    help)
        show_help
        ;;
esac

log "Operação concluída!"
