# Guía para Aplicar Correcciones de Estabilidad de Spans

## Problema Identificado
Los spans retornados por las consultas decrecen de ~2000 a ~700 a lo largo del test debido a:
1. Jitter aleatorio en ventanas de tiempo
2. Time buckets alejándose del presente
3. Falta de configuración de retención explícita en Tempo
4. Límite bajo de consultas (1000)

## Cambios Realizados

### 1. Query Generator
- Eliminado jitter aleatorio para ventanas consistentes
- Límite aumentado: 1000 → 5000 spans
- **Requiere rebuild de la imagen**

### 2. Time Buckets
- Ventanas más cortas y recientes (10s-15m vs 10s-1h)
- Mayor peso en datos recientes (80% en últimos 5m)

### 3. Tempo Configuration
- Block retention: 2h
- Trace idle time: 30s  
- Max block bytes: 500MB

## Pasos de Aplicación

### Paso 1: Rebuild Query Generator

```bash
cd generators/query-generator
make docker-build
make docker-push
```

**Nota**: Asegúrate de que `Makefile` tenga tu repositorio correcto.

### Paso 2: Recrear Tempo con Nueva Configuración

```bash
# Borrar Tempo existente
oc delete tempomonolithic simplest -n tempo-perf-test

# Esperar a que termine
oc wait --for=delete tempomonolithic/simplest -n tempo-perf-test --timeout=120s

# Aplicar nueva configuración
oc apply -f deploy/tempo-monolithic/base/tempo.yaml -n tempo-perf-test

# Verificar que esté listo
oc wait --for=condition=Ready tempomonolithic/simplest -n tempo-perf-test --timeout=300s
```

### Paso 3: Actualizar Query Generator en Cluster

```bash
# Recrear ConfigMap con nuevos time buckets
oc delete configmap query-load-config -n tempo-perf-test --ignore-not-found=true

# El script run-perf-tests.sh lo regenerará automáticamente con la nueva config

# Recrear deployment para usar nueva imagen
oc delete deployment query-load-generator -n tempo-perf-test --ignore-not-found=true
oc apply -f generators/query-generator/manifests/deployment.yaml -n tempo-perf-test
```

### Paso 4: Ejecutar Test de Validación

```bash
cd perf-tests/scripts

# Test corto para validar (5 minutos)
./run-perf-tests.sh -d 5m -l low -K

# Verificar spans retornados en logs del query generator
oc logs -f deployment/query-load-generator -n tempo-perf-test | grep "spans:"
```

## Resultados Esperados

Con estos cambios deberías ver:
- ✅ Spans retornados **más estables** (~1800-2200 en lugar de 2000→700)
- ✅ Menor variabilidad entre mediciones
- ✅ Degradación eliminada o reducida significativamente

## Validación

Genera gráficas después del test:

```bash
cd perf-tests/scripts
./generate-charts.py ../results
```

Compara la nueva gráfica `timeseries_spans_returned.png` con la anterior.

## Rollback (si es necesario)

Si encuentras problemas:

```bash
# Restaurar archivos originales
git checkout generators/query-generator/main.go
git checkout generators/query-generator/config.yaml
git checkout deploy/tempo-monolithic/base/tempo.yaml

# Rebuild y redeploy
cd generators/query-generator && make docker-build docker-push
oc delete tempomonolithic simplest -n tempo-perf-test
oc apply -f deploy/tempo-monolithic/base/tempo.yaml -n tempo-perf-test
```

## Notas Adicionales

### Alternativa: Solo Aplicar Cambios en Config (sin rebuild)

Si no puedes hacer rebuild del query generator inmediatamente:

1. **Aplica solo cambios en `config.yaml` y `tempo.yaml`**:
   ```bash
   # Actualizar Tempo
   oc apply -f deploy/tempo-monolithic/base/tempo.yaml -n tempo-perf-test
   
   # Los cambios de time buckets se aplicarán en el próximo test
   # (el script regenera el ConfigMap automáticamente)
   ```

2. **Ejecuta test de validación**:
   ```bash
   ./run-perf-tests.sh -d 10m -l medium -K
   ```

Esto dará mejora parcial (time buckets + retención) sin necesitar rebuild.

### Monitoreo Durante el Test

Mientras corre el test, monitorea:

```bash
# Spans retornados (cada consulta)
oc logs -f deployment/query-load-generator -n tempo-perf-test | grep -E "spans: [0-9]+"

# Métricas de Tempo
oc port-forward -n tempo-perf-test svc/tempo-simplest 3200:3200
# Abrir http://localhost:3200/metrics en navegador

# Buscar métricas relevantes:
# - tempo_ingester_live_traces
# - tempo_ingester_blocks_flushed_total  
# - tempo_query_frontend_queries_total
```





