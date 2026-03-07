#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR" && pwd)"

source $SCRIPT_DIR/style.sh # Загрузка стилизированного логирования

PLANTUML_JAR="$ROOT_DIR/bin/plantuml.jar"            # 1. Локальный в репо
PLANTUML_ENV="${PLANTUML_JAR_PATH:-}"                # 2. Переменная окружения
PLANTUML_SYS="$(which plantuml 2>/dev/null || true)" # 3. Системный (если в PATH)
PLANTUML_CMD=""                                      # 4. Глобальная переменная для хранения найденного пути

PLANTUML_JAR="$ROOT_DIR/bin/plantuml.jar"
CHARTS_DIR="${CHARTS_DIR:-$ROOT_DIR}"

OUTPUT_FORMAT="svg"

# Поиск PlantUML
_find_plantuml() {
    # Приоритет 1: Локальный файл в репозитории
    if [ -f "$PLANTUML_JAR" ]; then
        PLANTUML_CMD="$PLANTUML_JAR"
        log_info "Используется локальный PlantUML: $PLANTUML_CMD"
        return 0
    fi

    # Приоритет 2: Переменная окружения (проверка, что она не пустая)
    if [ -n "$PLANTUML_ENV" ] && [ -f "$PLANTUML_ENV" ]; then
        PLANTUML_CMD="$PLANTUML_ENV"
        log_info "Используется PlantUML из переменной окружения: $PLANTUML_CMD"
        return 0
    fi

    # Приоритет 3: Системный plantuml
    if [ -n "$PLANTUML_SYS" ]; then
        PLANTUML_CMD="$PLANTUML_SYS"
        log_info "Используется системный PlantUML: $PLANTUML_CMD"
        return 0
    fi

    # Ничего не найдено
    log_error "PlantUML не найден!"
    log_info "Варианты решения:"
    log_log "  1. Скачать jar в папку bin/ репозитория"
    log_log "  2. Установить системно: sudo apt install plantuml / brew install plantuml"
    log_log "  3. Задайть переменную: export PLANTUML_JAR_PATH=/path/to/plantuml.jar"
    exit 1
}

# Проверка рабочей директории
_check_work_directory() {
    if [ ! -d "$CHARTS_DIR" ]; then
        log_error "Анализируемая директория с диаграммами не найдена: $CHARTS_DIR"
        exit 1
    fi

    log_info "Анализируемая директория с диаграммами: $CHARTS_DIR"
    return 0
}

# Генерация SVG
_generate_svg() {
    local file="$1"
    
    if [ ! -f "$file" ]; then
        log_warn "Файл не найден: $file"
        return 1
    fi

    local svg_file="${file%.*}.svg"
    
    log_info "Генерация: $(basename "$file") -> $(basename "$svg_file")"
    if [[ "$PLANTUML_CMD" == *.jar ]]; then
        cat $file | java -jar "$PLANTUML_CMD" --svg -pipe > $svg_file || true
    else
        cat $file | "$PLANTUML_CMD" --svg -pipe > "$svg_file" || true
    fi
    
    if [ -f "$svg_file" ]; then
        return 0
    else
        log_error "
        
        Ошибка генерации: $(basename "$file")"
        return 1
    fi
}

# Режим: Конкретный файл
mode_file() {
    local file="$1"
    
    if [ -z "$file" ]; then
        log_error "Не указан файл"
        exit 1
    fi
    
    if [ ! -f "$file" ]; then
        log_error "Файл не найден: $file"
        exit 1
    fi
    
    _generate_svg "$file" false
}

# Режим: Все файлы
mode_file_all() {
    log_step "Режим: Все файлы"
        
    local count=0
    
    while IFS= read -r -d '' file; do
        if _generate_svg "$file" false; then
            ((count++)) || true
        fi
    done < <(find "$CHARTS_DIR" -type f \( -name "*.wsd" -o -name "*.puml" \) -print0)
    
    log_info "Всего сгенерировано: $count файлов"
}

# Режим: Очистка SVG
mode_clean() {
    log_step "Режим: Очистка SVG"
    
    local file="$1"
    
    if [ ! -f "$file" ]; then
        log_warn "Файл не найден: $file"
        exit 1
    fi

    local svg_file="${file%.*}.svg"

    if [ ! -f "$svg_file" ]; then
        log_log "Svg представление для $file не найдено"
        exit 0
    fi
    
    find "$CHARTS_DIR" -type f -name "*.$OUTPUT_FORMAT" -delete
    
    if [ -f "$svg_file" ]; then
        log_error "Ошибка генерации: $(basename "$file")"
        exit 1
    else
        log_info "Удален $svg_file для $file"
        exit 0
    fi
}

mode_clean_all() {
    log_step "Режим: Очистка всех SVG"
    
    local count
    count=$(find "$CHARTS_DIR" -type f -name "*.$OUTPUT_FORMAT" | wc -l)
    
    find "$CHARTS_DIR" -type f -name "*.$OUTPUT_FORMAT" -delete
    
    log_info "Удалено SVG файлов: $count"
}

# Режим: Staged файлы (для pre-commit)
mode_staged() {
    log_step "Режим: Staged files (pre-commit)"

    local GIT_ROOT_DIR=$(git rev-parse --show-toplevel 2>/dev/null)
    if [ $? -eq 0 ]; then
        log_info "Корень проекта: $GIT_ROOT_DIR"
    else
        log_error "Ошибка: текущая папка не является частью Git-репозитория"
    fi
    
    local FILES
    FILES=$(git diff --cached --name-only --diff-filter=ACM 2>/dev/null | grep -E '\.(wsd|puml)$' || true)
    
    if [ -z "$FILES" ]; then
        log_info "Нет изменённых .wsd/.puml файлов"
        exit 0
    fi
    
    local count=0
    local failed=0
    
    while IFS= read -r file; do
        local full_path_file="$GIT_ROOT_DIR/$file"
        if [ -f "$full_path_file" ]; then
            if _generate_svg "$full_path_file"; then
                git add "${full_path_file%.*}.$OUTPUT_FORMAT" 2>/dev/null || true
                ((count++)) || true
            else
                ((failed++)) || true
            fi
        else
            log_warn "Файл не найден: $full_path_file"
        fi
    done <<< "$FILES"
    
    log_info "Обработано файлов: $count"
    
    if [ $failed -gt 0 ]; then
        log_error "Не сгенерировалось файлов: $failed"
        exit 1
    fi
}

# Режим: Проверка актуальности (для CI)
mode_check() {
    log_step "Режим: Проверка актуальности (CI)"
    
    local temp_dir=$(mktemp -d)
    local absence=0       # отсутсвтие svg файла
    local incorrect=0     # ошибка генерации svg файлы
    local mismatch=0      # несоответствие svg файлов
    local failed=0        # Суммарное провалов
    local checked=0       # Суммарное количество проверенных файлов
    
    while IFS= read -r -d '' file; do
        ((checked++)) || true
        local svg_file="${file%.*}.$OUTPUT_FORMAT"
        local temp_svg="$temp_dir/$(basename "$svg_file")"
        
        log_log "файл №$checked"
        log_info "Проверка: $file"
        
        if [[ "$PLANTUML_CMD" == *.jar ]]; then
            cat $file | java -jar "$PLANTUML_CMD" --svg -pipe > $temp_svg || true
        else
            cat $file | "$PLANTUML_CMD" --svg -pipe > $temp_svg || true
        fi
        
        if [ -f "$svg_file" ] && [ -f "$temp_svg" ]; then
            # diff возвращает 0 если файлы одинаковы, 1 если отличаются
            if ! diff -q "$svg_file" "$temp_svg" >/dev/null 2>&1; then
                log_warn "Несоответсвие SVG: $(basename "$file")"
                ((mismatch++)) || true
                ((failed++)) || true
            else
                log_info "Актуален: $(basename "$file")"
            fi
        elif [ ! -f "$svg_file" ]; then
            log_warn "Отсутствует SVG: $(basename "$file")"
            ((absence++)) || true
            ((failed++)) || true
        elif [ ! -f "$temp_svg" ]; then
            log_warn "Ошибка генерации: $(basename "$file")"
            ((incorrect)) || true
            ((failed++)) || true
        fi
    done < <(find "$CHARTS_DIR" -type f \( -name "*.wsd" -o -name "*.puml" \) -print0 2>/dev/null)
    
    if [ $checked -eq 0 ]; then
        log_warn "Файлы .wsd/.puml не найдены в $CHARTS_DIR"
    fi
    
    rm -rf "$temp_dir" || true
    
    log_log "Итог: (Проверено файлов: $checked) (Отсутвие генераций: $absence) (Ошибки генерации: $incorrect) (Несоответствие генераций: $mismatch)"

    if [ $failed -gt 0 ]; then
        log_error "Проверка не пройдена. Найдено проблем: $failed"
        log_info "Выполните: $0 all"
        exit 1
    else
        log_info "Все SVG актуальны (проверено: $checked)"
    fi
}

# === HELP =====================================================================

usage() {
    cat << EOF
PlantUML Hook Script

Использование: [CHARTS_DIR=<путь к директории>] $0 <режим> [аргументы]

Переменные окружения:
  CHARTS_DIR - путь к анализируемой директории. По умолчанию корневая директория скрипта

Режимы:
  file <путь>     Сгенерировать SVG для конкретного файла
  file_all        Сгенерировать SVG для всех диаграмм
  clean           Удалить SVG представление для указанного исходного файла (wsd|puml)
  clean_all       Удалить все SVG файлы
  staged          Обработать staged файлы (для pre-commit)
  check           Проверить актуальность SVG (для CI)

Примеры:
  $0 help
  $0 file <путь>
  $0 file_all
  $0 clean
  $0 staged
  $0 check

EOF
}

# === MAIN =====================================================================

main() {
    if [ $# -lt 1 ]; then
        usage
        exit 1
    fi

    if [[ ($1 == "file" || $1 == "clean") && $# -lt 2 ]]; then
        echo "Для данного режима необходимо два параметра"
        exit 1
    fi

    _find_plantuml
    _check_work_directory

    case "$1" in
        help|--help|-h)
            usage
            exit 0
            ;;
        file)
            mode_file "$2"
            ;;
        file_all)
            mode_file_all
            ;;
        clean)
            mode_clean "$2"
            ;;
        clean_all)
            mode_clean_all
            ;;
        staged)
            mode_staged
            ;;
        check)
            mode_check
            ;;
        *)
            log_error "Неизвестный режим: $1"
            exit 1
            ;;
    esac
}

main $@
