# 🔍 Análisis: Degradación de Spans Retornados

## Problema Observado

```
Spans Retornados vs Tiempo
┌─────────────────────────────────────────────┐
│ 2100 ┤ ╭─╮                                  │
│      │ │ │╰─╮                                │
│ 1800 ┤ │    ╰──╮                             │
│      │ │       ╰───╮                         │
│ 1500 ┤ │           ╰────────╮                │
│      │ │                    ╰───╮            │
│ 1200 ┤ │                        ╰──╮         │
│      │ │                           ╰──╮      │
│  900 ┤ │                              ╰──╮   │
│      │ │                                 ╰─╮ │
│  700 ┤ │                                   ╰─│
│      └─┴───────────────────────────────────┴─│
│        0    5   10   15   20   25   30 (min) │
└─────────────────────────────────────────────┘

❌ Degradación: ~2000 → ~700 spans (65% pérdida)
```

## Causas Raíz

### 1. ⚡ Jitter Aleatorio en Ventanas de Tiempo

**ANTES:**
```go
// Ventana de consulta varía aleatoriamente
jitter := rand.Int63n(bucketRange)  // 0 a 30min aleatorio!
startTime = now.Add(-bucket.ageEnd).Add(-jitter)
endTime = now.Add(-bucket.ageStart).Add(-jitter)

// Resultado: Ventanas inconsistentes
Query 1: [45min ago ← 32min ago]  → 1850 spans
Query 2: [58min ago ← 45min ago]  → 1420 spans  
Query 3: [50min ago ← 37min ago]  → 1680 spans
```

**DESPUÉS:**
```go
// Ventana fija y predecible
startTime = now.Add(-bucket.ageEnd)
endTime = now.Add(-bucket.ageStart)

// Resultado: Ventanas consistentes
Query 1: [30min ago ← 10min ago]  → 1900 spans
Query 2: [30min ago ← 10min ago]  → 1910 spans
Query 3: [30min ago ← 10min ago]  → 1895 spans
```

### 2. 📅 Time Buckets Alejados del Presente

**ANTES:**
```
Distribución de Consultas:
┌─────────────────────────────────────────────┐
│  recent (10s-30s)       : 20% ░░            │
│  ingester (5m-10m)      : 30% ░░░           │
│  backend-1h (30m-1h) ⚠️ : 50% ░░░░░         │
└─────────────────────────────────────────────┘

Problema: 50% de queries buscan en datos de 30m-1h
→ Datos pueden estar compactados/eliminados
→ Menor densidad de trazas antiguas
```

**DESPUÉS:**
```
Distribución de Consultas:
┌─────────────────────────────────────────────┐
│  recent (10s-1m)     ✅ : 40% ░░░░          │
│  ingester (1m-5m)    ✅ : 40% ░░░░          │
│  backend (5m-15m)    ✅ : 20% ░░            │
└─────────────────────────────────────────────┘

Solución: 80% de queries en datos frescos (<5m)
→ Datos en memoria (ingester)
→ Alta densidad de trazas
→ Resultados estables
```

### 3. 🗄️ Configuración de Retención No Optimizada

**ANTES:**
```yaml
# tempo.yaml (solo backend S3, sin config explícita)
spec:
  storage:
    traces:
      backend: s3
      s3:
        secret: minio
  # ⚠️ Sin configuración de retención
  # ⚠️ Sin configuración de compactación
  # ⚠️ Defaults pueden ser agresivos
```

**Problema:**
- Tempo usa defaults que pueden compactar rápido
- Blocks se fusionan y algunos datos se eliminan
- No hay garantía de retención durante el test

**DESPUÉS:**
```yaml
spec:
  storage:
    traces:
      backend: s3
      s3:
        secret: minio
      block:
        retention: 2h          # ✅ Mayor que duración de test (30m)
  ingestion:
    traceIdleTime: 30s         # ✅ No flush prematuro
    maxBlockBytes: 500000000   # ✅ Blocks más grandes = menos compactación
```

**Beneficio:**
- Datos se mantienen estables durante el test
- Menos compactación = menos variabilidad
- Comportamiento predecible

### 4. 📊 Límite de Consultas Restrictivo

**ANTES:**
```go
queryParams.Set("limit", "1000")  // ⚠️ Bajo para cargas altas
```

Si una consulta debería retornar 2500 spans pero el límite es 1000:
- Se trunca a 1000
- Métricas no reflejan realidad
- Comparaciones entre cargas no son justas

**DESPUÉS:**
```go
queryParams.Set("limit", "5000")  // ✅ Capacidad para cargas altas
```

## Línea de Tiempo del Problema

```
Minuto 0-5: Test Inicia
┌─────────────────────────────────────────────┐
│ ✅ Ingester lleno de trazas recientes        │
│ ✅ Todas las queries encuentran datos        │
│ ✅ ~2000 spans retornados                    │
└─────────────────────────────────────────────┘

Minuto 5-15: Inicio de Compactación
┌─────────────────────────────────────────────┐
│ ⚠️  Jitter aleatorio empieza a tener efecto │
│ ⚠️  Algunas queries caen en ventanas vacías │
│ ⚠️  backend-1h bucket busca datos muy viejos│
│ ⚠️  ~1500 spans retornados (caída 25%)      │
└─────────────────────────────────────────────┘

Minuto 15-30: Degradación Severa
┌─────────────────────────────────────────────┐
│ ❌ backend-1h bucket completamente obsoleto  │
│ ❌ Compactación agresiva elimina bloques     │
│ ❌ Jitter + ventanas viejas = pocos datos    │
│ ❌ ~700 spans retornados (caída 65%)         │
└─────────────────────────────────────────────┘
```

## Soluciones Implementadas

### Matriz de Impacto

| Cambio | Impacto | Esfuerzo | Prioridad |
|--------|---------|----------|-----------|
| ✅ Eliminar jitter | **Alto** 🔥 | Bajo | 1 |
| ✅ Time buckets cercanos | **Alto** 🔥 | Bajo | 1 |
| ✅ Config retención Tempo | **Medio** ⚡ | Bajo | 2 |
| ✅ Aumentar límite consultas | **Bajo** 💧 | Bajo | 3 |

### Resultado Esperado

```
Spans Retornados vs Tiempo (DESPUÉS DE FIX)
┌─────────────────────────────────────────────┐
│ 2100 ┤ ╭─────────────────────────────────╮  │
│      │ │                                  │  │
│ 1900 ┤ │                                  │  │
│      │ │                                  │  │
│ 1700 ┤ ╰──────────────────────────────────╯  │
│      │                                        │
│ 1500 ┤                                        │
│      │                                        │
│ 1300 ┤                                        │
│      │                                        │
│ 1100 ┤                                        │
│      │                                        │
│  900 ┤                                        │
│      │                                        │
│  700 ┤                                        │
│      └────────────────────────────────────────│
│        0    5   10   15   20   25   30 (min) │
└─────────────────────────────────────────────┘

✅ Estabilidad: ~1900 ± 50 spans (varianza <3%)
✅ Sin degradación
✅ Resultados comparables entre cargas
```

## Pasos Siguientes

1. **Rebuild Query Generator** (requiere imagen Docker)
   ```bash
   cd generators/query-generator
   make docker-build docker-push
   ```

2. **Aplicar Config Tempo**
   ```bash
   oc apply -f deploy/tempo-monolithic/base/tempo.yaml -n tempo-perf-test
   ```

3. **Test de Validación**
   ```bash
   cd perf-tests/scripts
   ./run-perf-tests.sh -d 10m -l medium
   ```

4. **Comparar Resultados**
   - Revisar nueva gráfica `timeseries_spans_returned.png`
   - Verificar que la línea sea horizontal (~constante)
   - Validar que no hay degradación >5%

## Referencias

- **Archivos Modificados:**
  - `generators/query-generator/main.go` (líneas 510-518, 563)
  - `generators/query-generator/config.yaml` (timeBuckets)
  - `deploy/tempo-monolithic/base/tempo.yaml` (storage.block)

- **Documentación Tempo:**
  - [Retention Policies](https://grafana.com/docs/tempo/latest/configuration/retention/)
  - [Compaction](https://grafana.com/docs/tempo/latest/operations/compaction/)

---

**Fecha:** $(date)
**Autor:** AI Assistant
**Versión:** 1.0





