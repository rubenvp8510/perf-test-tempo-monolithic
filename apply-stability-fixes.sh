#!/usr/bin/env bash
set -euo pipefail

#
# apply-stability-fixes.sh - Aplicar correcciones para estabilizar spans retornados
#
# Este script aplica todas las correcciones necesarias para resolver
# la degradación de spans retornados observada en los tests de rendimiento.
#

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAMESPACE="tempo-perf-test"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${GREEN}✅${NC} $1"; }
log_warn() { echo -e "${YELLOW}⚠️${NC} $1"; }
log_error() { echo -e "${RED}❌${NC} $1"; }
log_section() { echo -e "\n${BLUE}═══════════════════════════════════════════════${NC}"; echo -e "${BLUE}  $1${NC}"; echo -e "${BLUE}═══════════════════════════════════════════════${NC}\n"; }

# Parse arguments
SKIP_BUILD=false
SKIP_TEMPO=false
VALIDATE=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --skip-build)
            SKIP_BUILD=true
            shift
            ;;
        --skip-tempo)
            SKIP_TEMPO=true
            shift
            ;;
        --validate-only)
            VALIDATE=true
            shift
            ;;
        -h|--help)
            cat <<EOF
Uso: $0 [opciones]

Opciones:
  --skip-build      Omitir rebuild del query generator (solo aplica configs)
  --skip-tempo      No recrear Tempo (solo actualizar query generator)
  --validate-only   Solo ejecutar test de validación (no aplicar cambios)
  -h, --help        Mostrar esta ayuda

Ejemplos:
  $0                        # Aplicar todos los cambios
  $0 --skip-build           # Solo aplicar configs (sin rebuild)
  $0 --skip-tempo           # Solo actualizar query generator
  $0 --validate-only        # Solo validar con test corto
EOF
            exit 0
            ;;
        *)
            log_error "Opción desconocida: $1"
            exit 1
            ;;
    esac
done

log_section "Correcciones de Estabilidad de Spans"

echo "📊 Problema: Spans retornados decrecen de ~2000 a ~700"
echo "🎯 Solución: Ventanas fijas + time buckets cercanos + retención explícita"
echo ""

# Validation only mode
if [ "$VALIDATE" = true ]; then
    log_section "Modo Validación - Ejecutando Test"
    log_info "Ejecutando test de 10 minutos con carga 'medium'..."
    
    cd "$SCRIPT_DIR/perf-tests/scripts"
    ./run-perf-tests.sh -d 10m -l medium -K
    
    log_info "Test completado. Revisa las gráficas en perf-tests/results/charts/"
    log_info "Busca: report-*-timeseries_spans_returned.png"
    exit 0
fi

# Check prerequisites
log_section "Verificando Prerequisitos"

if ! command -v oc &> /dev/null; then
    log_error "oc (OpenShift CLI) no está instalado"
    exit 1
fi
log_info "OpenShift CLI encontrado"

if ! oc whoami &> /dev/null; then
    log_error "No estás conectado a un cluster OpenShift"
    exit 1
fi
log_info "Conectado a cluster: $(oc whoami --show-server)"

if ! oc get namespace "$NAMESPACE" &> /dev/null; then
    log_error "Namespace '$NAMESPACE' no existe"
    exit 1
fi
log_info "Namespace '$NAMESPACE' existe"

# Step 1: Rebuild query generator (optional)
if [ "$SKIP_BUILD" = false ]; then
    log_section "Paso 1: Rebuild Query Generator"
    
    if ! command -v docker &> /dev/null && ! command -v podman &> /dev/null; then
        log_warn "Docker/Podman no encontrado. Omitiendo rebuild..."
        log_warn "Los cambios en main.go no se aplicarán hasta que hagas rebuild manual."
        SKIP_BUILD=true
    else
        log_info "Compilando nueva imagen del query generator..."
        
        cd "$SCRIPT_DIR/generators/query-generator"
        
        if [ -f Makefile ]; then
            log_info "Ejecutando: make docker-build docker-push"
            if make docker-build docker-push; then
                log_info "Imagen compilada y subida exitosamente"
            else
                log_error "Falló el build de la imagen"
                log_warn "Continuando con configs solamente (sin cambios en código Go)"
                SKIP_BUILD=true
            fi
        else
            log_warn "Makefile no encontrado. Necesitarás hacer build manual:"
            log_warn "  cd generators/query-generator"
            log_warn "  docker build -t <tu-repo>/query-load-generator:latest ."
            log_warn "  docker push <tu-repo>/query-load-generator:latest"
            SKIP_BUILD=true
        fi
    fi
else
    log_section "Paso 1: Rebuild Query Generator [OMITIDO]"
    log_warn "Omitiendo rebuild. Solo se aplicarán cambios en configs."
fi

# Step 2: Update Tempo configuration
if [ "$SKIP_TEMPO" = false ]; then
    log_section "Paso 2: Actualizar Configuración de Tempo"
    
    log_info "Verificando si Tempo existe..."
    if ! oc get tempomonolithic simplest -n "$NAMESPACE" &> /dev/null; then
        log_warn "TempoMonolithic 'simplest' no existe. Creándolo..."
        oc apply -f "$SCRIPT_DIR/deploy/tempo-monolithic/base/tempo.yaml" -n "$NAMESPACE"
    else
        log_info "Actualizando TempoMonolithic 'simplest'..."
        
        # Delete and recreate for clean state
        log_info "Eliminando instancia existente..."
        oc delete tempomonolithic simplest -n "$NAMESPACE"
        
        log_info "Esperando a que se elimine completamente..."
        timeout=120
        elapsed=0
        while oc get tempomonolithic simplest -n "$NAMESPACE" &>/dev/null && [ $elapsed -lt $timeout ]; do
            sleep 5
            elapsed=$((elapsed + 5))
        done
        
        log_info "Creando nueva instancia con configuración actualizada..."
        oc apply -f "$SCRIPT_DIR/deploy/tempo-monolithic/base/tempo.yaml" -n "$NAMESPACE"
    fi
    
    log_info "Esperando a que Tempo esté listo..."
    if oc wait --for=condition=Ready tempomonolithic/simplest -n "$NAMESPACE" --timeout=300s 2>/dev/null; then
        log_info "Tempo está listo"
    else
        log_warn "Timeout esperando Tempo. Verifica manualmente:"
        log_warn "  oc get tempomonolithic simplest -n $NAMESPACE"
        log_warn "  oc get pods -n $NAMESPACE -l app.kubernetes.io/name=tempo"
    fi
else
    log_section "Paso 2: Actualizar Tempo [OMITIDO]"
    log_warn "No se recreará Tempo. Asegúrate de que esté corriendo."
fi

# Step 3: Update query generator
log_section "Paso 3: Actualizar Query Generator"

log_info "Eliminando ConfigMap anterior..."
oc delete configmap query-load-config -n "$NAMESPACE" --ignore-not-found=true

log_info "Eliminando deployment anterior..."
oc delete deployment query-load-generator -n "$NAMESPACE" --ignore-not-found=true --wait=true

log_info "Esperando a que pods terminen..."
timeout=60
elapsed=0
while oc get pods -n "$NAMESPACE" -l app=query-load-generator --no-headers 2>/dev/null | grep -q . && [ $elapsed -lt $timeout ]; do
    sleep 5
    elapsed=$((elapsed + 5))
done

log_info "Desplegando nuevo query generator..."
# Extract only deployment, roles, etc (ConfigMap is generated by test script)
oc apply -f <(kubectl apply -f "$SCRIPT_DIR/generators/query-generator/manifests/deployment.yaml" --dry-run=client -o yaml | \
             yq eval 'select(.kind != "ConfigMap")' -) -n "$NAMESPACE" 2>/dev/null || \
oc apply -f "$SCRIPT_DIR/generators/query-generator/manifests/deployment.yaml" -n "$NAMESPACE"

log_info "Esperando a que query generator esté listo..."
if oc wait --for=condition=Available deployment/query-load-generator -n "$NAMESPACE" --timeout=120s 2>/dev/null; then
    log_info "Query generator está listo"
else
    log_warn "Timeout esperando query generator. Verifica manualmente:"
    log_warn "  oc get deployment query-load-generator -n $NAMESPACE"
    log_warn "  oc get pods -n $NAMESPACE -l app=query-load-generator"
fi

# Summary
log_section "Resumen de Cambios Aplicados"

echo "✅ Cambios en código (query generator):"
if [ "$SKIP_BUILD" = false ]; then
    echo "   - Eliminado jitter aleatorio en ventanas de tiempo"
    echo "   - Límite de consultas aumentado: 1000 → 5000"
else
    echo "   - ⚠️ Omitido (no se hizo rebuild)"
fi

echo ""
echo "✅ Cambios en configuración:"
echo "   - Time buckets más cercanos al presente:"
echo "     • recent: 10s-1m (40%)"
echo "     • ingester: 1m-5m (40%)"
echo "     • backend: 5m-15m (20%)"

if [ "$SKIP_TEMPO" = false ]; then
    echo ""
    echo "✅ Cambios en Tempo:"
    echo "   - Block retention: 2h"
    echo "   - Trace idle time: 30s"
    echo "   - Max block bytes: 500MB"
fi

log_section "Próximos Pasos"

echo "1. Ejecutar test de validación:"
echo "   cd perf-tests/scripts"
echo "   ./run-perf-tests.sh -d 10m -l medium"
echo ""
echo "2. Revisar gráficas generadas:"
echo "   ls -lh perf-tests/results/charts/report-*-timeseries_spans_returned.png"
echo ""
echo "3. Comparar con resultados anteriores:"
echo "   Busca estabilidad: línea horizontal ~1900 spans"
echo "   Sin degradación: varianza <5%"
echo ""
echo "4. Si todo se ve bien, ejecutar suite completa:"
echo "   ./run-perf-tests.sh -d 30m"

log_section "Documentación"

echo "📖 Lee los documentos generados para más detalles:"
echo "   - PROBLEMA_Y_SOLUCION.md - Análisis detallado del problema"
echo "   - APPLY_FIXES.md         - Guía completa de aplicación"

log_info "¡Correcciones aplicadas exitosamente!"





