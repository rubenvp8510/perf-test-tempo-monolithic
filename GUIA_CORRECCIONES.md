# 🎯 Guía Rápida: Corregir Degradación de Spans

## 📖 Inicio Rápido (5 minutos)

### 1️⃣ Entender el Problema
👉 **Lee primero:** `COMPARACION_ANTES_DESPUES.md`
- Visualización clara del problema
- Gráficas antes vs después
- Impacto esperado

### 2️⃣ Aplicar la Solución
👉 **Ejecuta:**
```bash
./apply-stability-fixes.sh
```

### 3️⃣ Validar Resultados
👉 **Ejecuta test corto:**
```bash
cd perf-tests/scripts
./run-perf-tests.sh -d 10m -l medium
```

### 4️⃣ Revisar Gráficas
```bash
ls -lh perf-tests/results/charts/report-*-timeseries_spans_returned.png
```

**Busca:** Línea horizontal sin degradación ✅

---

## 📚 Documentación Completa

### Para Diferentes Necesidades

| Necesito... | Lee este documento | Tiempo |
|-------------|-------------------|--------|
| 🚀 **Empezar YA** | Este documento (arriba) | 5 min |
| 📊 **Ver comparación visual** | `COMPARACION_ANTES_DESPUES.md` | 10 min |
| 📋 **Resumen ejecutivo** | `RESUMEN_CAMBIOS.md` | 15 min |
| 🔍 **Análisis técnico profundo** | `PROBLEMA_Y_SOLUCION.md` | 30 min |
| 🛠️ **Aplicación paso a paso** | `APPLY_FIXES.md` | 20 min |

### Árbol de Documentos

```
📁 Documentación de Correcciones
│
├── 🎯 GUIA_CORRECCIONES.md (ESTE ARCHIVO)
│   └─→ Índice y navegación rápida
│
├── 📊 COMPARACION_ANTES_DESPUES.md ⭐ RECOMENDADO
│   ├─→ Gráficas antes/después
│   ├─→ Comparación numérica
│   ├─→ Visualización de cambios
│   └─→ Criterios de éxito
│
├── 📋 RESUMEN_CAMBIOS.md
│   ├─→ Resumen ejecutivo
│   ├─→ Checklist de verificación
│   ├─→ Troubleshooting
│   └─→ Notas importantes
│
├── 🔍 PROBLEMA_Y_SOLUCION.md
│   ├─→ Análisis detallado del problema
│   ├─→ Causas raíz con diagramas
│   ├─→ Línea de tiempo
│   └─→ Referencias técnicas
│
├── 🛠️ APPLY_FIXES.md
│   ├─→ Guía paso a paso
│   ├─→ Comandos completos
│   ├─→ Validación
│   └─→ Rollback instructions
│
└── 🔧 apply-stability-fixes.sh
    └─→ Script de aplicación automatizada
```

---

## 🎬 Flujos de Trabajo Recomendados

### Opción A: Usuario Rápido (15 minutos)

```bash
# 1. Leer comparación visual
cat COMPARACION_ANTES_DESPUES.md

# 2. Aplicar cambios automáticamente
./apply-stability-fixes.sh

# 3. Ejecutar test de validación
cd perf-tests/scripts && ./run-perf-tests.sh -d 10m -l medium

# 4. Revisar resultados
ls -lh ../results/charts/report-*-timeseries_spans_returned.png
```

### Opción B: Usuario Detallista (45 minutos)

```bash
# 1. Entender el problema a fondo
cat PROBLEMA_Y_SOLUCION.md

# 2. Revisar resumen ejecutivo
cat RESUMEN_CAMBIOS.md

# 3. Seguir guía paso a paso
cat APPLY_FIXES.md
# ... ejecutar comandos manualmente ...

# 4. Validar y documentar resultados
cd perf-tests/scripts && ./run-perf-tests.sh -d 15m
```

### Opción C: Usuario Cauteloso (60 minutos)

```bash
# 1. Leer TODA la documentación
cat COMPARACION_ANTES_DESPUES.md
cat PROBLEMA_Y_SOLUCION.md
cat RESUMEN_CAMBIOS.md
cat APPLY_FIXES.md

# 2. Hacer backup de configuración actual
git stash
git checkout -b backup-before-fixes

# 3. Aplicar solo configs (sin rebuild)
./apply-stability-fixes.sh --skip-build

# 4. Validar parcialmente
cd perf-tests/scripts && ./run-perf-tests.sh -d 5m -l low

# 5. Si OK, aplicar cambios completos
./apply-stability-fixes.sh

# 6. Validación completa
./run-perf-tests.sh -d 15m -l medium

# 7. Suite completa si todo está bien
./run-perf-tests.sh -d 30m
```

---

## 🔑 Conceptos Clave (TL;DR)

### Problema
- **Síntoma:** Spans retornados decrece ~2100 → ~700 (67% pérdida)
- **Causa:** Jitter aleatorio + time buckets viejos + falta de retención

### Solución
- **Ventanas fijas:** Sin jitter aleatorio (consistencia)
- **Time buckets cercanos:** 80% en datos <5min (frescos)
- **Retención explícita:** 2h (protege datos durante test)

### Resultado Esperado
- **Estabilidad:** ~1900 ± 50 spans (varianza <3%)
- **Sin degradación:** Línea horizontal en gráficas
- **Comparabilidad:** Resultados reproducibles

---

## ✅ Checklist de Aplicación

Marca cada paso cuando lo completes:

### Preparación
- [ ] OpenShift CLI (`oc`) instalado y conectado
- [ ] Namespace `tempo-perf-test` existe
- [ ] Backup de configuración actual (opcional)

### Aplicación
- [ ] Leído `COMPARACION_ANTES_DESPUES.md`
- [ ] Ejecutado `./apply-stability-fixes.sh`
- [ ] Sin errores en la salida del script
- [ ] Tempo recreado exitosamente
- [ ] Query generator actualizado

### Validación
- [ ] Test de 10min ejecutado: `./run-perf-tests.sh -d 10m -l medium`
- [ ] Gráfica generada: `report-*-timeseries_spans_returned.png`
- [ ] Línea horizontal (no descendente) ✅
- [ ] Varianza baja (<5%) ✅
- [ ] Spans promedio ~1900 ✅

### Producción
- [ ] Suite completa ejecutada: `./run-perf-tests.sh -d 30m`
- [ ] Todas las cargas (low, medium, high, very-high) estables
- [ ] Reportes generados sin errores
- [ ] Nueva baseline establecida

---

## 🆘 Ayuda Rápida

### ¿Script falla por falta de Docker?
```bash
./apply-stability-fixes.sh --skip-build
```
Aplica solo configs (mejora parcial 40-60%)

### ¿Tempo no inicia?
```bash
oc logs -l app.kubernetes.io/name=tempo -n tempo-perf-test
oc describe tempomonolithic simplest -n tempo-perf-test
```

### ¿Query generator no retorna datos?
```bash
oc logs deployment/query-load-generator -n tempo-perf-test | grep "spans:"
oc get configmap query-load-config -n tempo-perf-test -o yaml
```

### ¿Resultados aún inestables?
1. Lee: `RESUMEN_CAMBIOS.md` (sección Troubleshooting)
2. Verifica logs: `oc logs -l app.kubernetes.io/name=tempo`
3. Consulta: `PROBLEMA_Y_SOLUCION.md` (Red Flags)

### ¿Necesito rollback?
```bash
git checkout generators/query-generator/main.go
git checkout generators/query-generator/config.yaml
git checkout deploy/tempo-monolithic/base/tempo.yaml

# Rebuild y redeploy
cd generators/query-generator && make docker-build docker-push
oc delete tempomonolithic simplest -n tempo-perf-test
oc apply -f ../../deploy/tempo-monolithic/base/tempo.yaml -n tempo-perf-test
```

---

## 📊 Métricas de Éxito

### ✅ Señales Positivas

| Métrica | Valor Esperado | Cómo Verificar |
|---------|----------------|----------------|
| **Spans promedio** | 1800-2000 | Gráfica `timeseries_spans_returned.png` |
| **Varianza** | <5% | Revisar desviación en logs |
| **Tendencia** | Horizontal | Visual en gráfica |
| **Degradación** | 0% | Comparar inicio vs final |

### ❌ Señales de Problema

| Señal | Indica | Acción |
|-------|--------|--------|
| Spans <1500 | Config no aplicada | Verificar ConfigMap |
| Degradación >10% | Image no actualizada | Rebuild query generator |
| Varianza >10% | Problema con Tempo | Revisar logs de Tempo |
| Línea descendente | Retención no aplicada | Verificar TempoMonolithic |

---

## 🎓 Material de Referencia

### Documentos Generados

1. **`GUIA_CORRECCIONES.md`** (este archivo)
   - Navegación y inicio rápido

2. **`COMPARACION_ANTES_DESPUES.md`** ⭐
   - Comparación visual completa
   - Mejor punto de partida

3. **`RESUMEN_CAMBIOS.md`**
   - Resumen ejecutivo
   - Troubleshooting

4. **`PROBLEMA_Y_SOLUCION.md`**
   - Análisis técnico profundo
   - Para entender causas raíz

5. **`APPLY_FIXES.md`**
   - Guía de aplicación detallada
   - Comandos paso a paso

### Scripts

- **`apply-stability-fixes.sh`**
  - Aplicación automatizada
  - Flags: `--skip-build`, `--skip-tempo`, `--validate-only`

### Archivos Modificados

```
generators/query-generator/
├── main.go              ← Eliminado jitter, límite 5000
└── config.yaml          ← Time buckets optimizados

deploy/tempo-monolithic/base/
└── tempo.yaml           ← Retención 2h, config ingestion
```

---

## 💡 Tips y Mejores Prácticas

### Antes de Aplicar
1. ✅ Lee `COMPARACION_ANTES_DESPUES.md` (10 min)
2. ✅ Verifica que Tempo esté corriendo
3. ✅ Haz backup si estás nervioso: `git stash`

### Durante la Aplicación
1. ✅ Usa el script automático: `./apply-stability-fixes.sh`
2. ✅ Lee los logs del script (muestran progreso)
3. ✅ Espera a que Tempo esté listo (puede tomar 2-3 min)

### Después de Aplicar
1. ✅ Test corto primero: 10 minutos
2. ✅ Revisa la gráfica antes de suite completa
3. ✅ Establece nueva baseline con suite de 30min

### Debugging
1. ✅ Siempre revisa logs primero
2. ✅ Usa `oc get pods` para ver estado
3. ✅ Consulta `RESUMEN_CAMBIOS.md` (Troubleshooting)

---

## 🎯 Resultado Final Esperado

Después de aplicar todas las correcciones:

```
✅ Gráfica muestra línea horizontal
✅ Spans estables: ~1900 ± 50
✅ Varianza <3%
✅ Sin degradación durante 30min
✅ Resultados reproducibles
✅ Comparaciones entre cargas válidas
```

**¡Listo para establecer nueva baseline de rendimiento!** 🚀

---

## 📞 Preguntas Frecuentes

**P: ¿Necesito rebuild obligatoriamente?**
R: No. Puedes usar `--skip-build` para aplicar solo configs (mejora parcial).

**P: ¿Mis tests anteriores son inválidos?**
R: Los resultados no son directamente comparables (ventanas diferentes). Establece nueva baseline.

**P: ¿Cuánto tiempo toma aplicar todo?**
R: 15-20 minutos (con rebuild). 5-10 minutos (sin rebuild).

**P: ¿Qué hago si algo falla?**
R: Lee `RESUMEN_CAMBIOS.md` (Troubleshooting) o haz rollback con git.

**P: ¿Puedo aplicar solo parte de los cambios?**
R: Sí. Usa `--skip-build` o `--skip-tempo` según necesites.

---

**Última actualización:** $(date)
**Versión:** 1.0
**Mantenedor:** AI Assistant

**🎉 ¡Éxito con tus tests de rendimiento!**





