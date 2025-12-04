#!/usr/bin/env bash
set -euo pipefail

#
# fix-query-scaling.sh - Apply proportional query scaling fixes
#
# This script fixes the resource consumption anomaly where low loads
# consumed more resources than high loads due to non-proportional
# query scaling.
#

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/perf-tests/config/loads.yaml"
IMPROVED_CONFIG="${SCRIPT_DIR}/perf-tests/config/loads-improved.yaml"
BACKUP_FILE="${CONFIG_FILE}.backup.$(date +%Y%m%d-%H%M%S)"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

echo ""
echo "╔════════════════════════════════════════════════════════════════╗"
echo "║     Tempo Performance Test - Query Scaling Fix                 ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo ""

#
# Show current vs improved configuration comparison
#
show_comparison() {
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}  Current vs Improved Query Scaling${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    
    printf "%-12s %10s %15s %15s %18s\n" \
        "Load" "Ingestion" "Current QPS" "Improved QPS" "QPS/MB Ratio"
    printf "%-12s %10s %15s %15s %18s\n" \
        "────────────" "──────────" "───────────────" "───────────────" "──────────────────"
    
    # Extract current values
    local low_qps_old=$(yq eval '.loads[] | select(.name == "low") | .queryQPS' "$CONFIG_FILE" 2>/dev/null || echo "25")
    local med_qps_old=$(yq eval '.loads[] | select(.name == "medium") | .queryQPS' "$CONFIG_FILE" 2>/dev/null || echo "50")
    local high_qps_old=$(yq eval '.loads[] | select(.name == "high") | .queryQPS' "$CONFIG_FILE" 2>/dev/null || echo "75")
    local vhigh_qps_old=$(yq eval '.loads[] | select(.name == "very-high") | .queryQPS' "$CONFIG_FILE" 2>/dev/null || echo "75")
    
    # Calculate ratios
    local low_ratio_old=$(echo "scale=1; $low_qps_old / 0.7" | bc)
    local med_ratio_old=$(echo "scale=1; $med_qps_old / 2.0" | bc)
    local high_ratio_old=$(echo "scale=1; $high_qps_old / 4.0" | bc)
    local vhigh_ratio_old=$(echo "scale=1; $vhigh_qps_old / 7.0" | bc)
    
    printf "${RED}%-12s${NC} %10s ${RED}%15s${NC} ${GREEN}%15s${NC} ${RED}%10s${NC} → ${GREEN}%5s${NC}\n" \
        "low" "0.7 MB/s" "$low_qps_old" "15" "$low_ratio_old" "21.4"
    
    printf "${RED}%-12s${NC} %10s ${RED}%15s${NC} ${GREEN}%15s${NC} ${RED}%10s${NC} → ${GREEN}%5s${NC}\n" \
        "medium" "2.0 MB/s" "$med_qps_old" "40" "$med_ratio_old" "20.0"
    
    printf "${RED}%-12s${NC} %10s ${RED}%15s${NC} ${GREEN}%15s${NC} ${RED}%10s${NC} → ${GREEN}%5s${NC}\n" \
        "high" "4.0 MB/s" "$high_qps_old" "80" "$high_ratio_old" "20.0"
    
    printf "${RED}%-12s${NC} %10s ${RED}%15s${NC} ${GREEN}%15s${NC} ${RED}%10s${NC} → ${GREEN}%5s${NC}\n" \
        "very-high" "7.0 MB/s" "$vhigh_qps_old" "140" "$vhigh_ratio_old" "20.0"
    
    echo ""
    echo -e "${YELLOW}⚠️  Problem:${NC} Query load doesn't scale proportionally with ingestion!"
    echo -e "   - Low load has ${RED}3.3x more queries per MB${NC} than very-high"
    echo -e "   - Very-high and high have the ${RED}SAME QPS${NC} despite 1.75x difference in ingestion"
    echo ""
    echo -e "${GREEN}✅  Fix:${NC} All loads now have consistent ~20 QPS per MB/s ratio"
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
}

#
# Show expected results
#
show_expected_results() {
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}  Expected Results After Fix${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    
    printf "%-12s %12s %10s %15s %15s\n" \
        "Load" "Ingestion" "QPS" "Expected CPU" "Expected Memory"
    printf "%-12s %12s %10s %15s %15s\n" \
        "────────────" "────────────" "──────────" "───────────────" "───────────────"
    
    printf "${GREEN}%-12s %12s %10s %15s %15s${NC}\n" \
        "low" "0.7 MB/s" "15" "~2.5 cores" "~2.5 GB"
    
    printf "${GREEN}%-12s %12s %10s %15s %15s${NC}\n" \
        "medium" "2.0 MB/s" "40" "~7.0 cores" "~4.0 GB"
    
    printf "${GREEN}%-12s %12s %10s %15s %15s${NC}\n" \
        "high" "4.0 MB/s" "80" "~14.0 cores" "~6.0 GB"
    
    printf "${GREEN}%-12s %12s %10s %15s %15s${NC}\n" \
        "very-high" "7.0 MB/s" "140" "~24.5 cores" "~8.0 GB"
    
    echo ""
    echo -e "${GREEN}✅${NC} Resources should now scale roughly ${GREEN}linearly${NC} with load!"
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
}

#
# Apply the fix
#
apply_fix() {
    local method="$1"
    
    echo -e "${BLUE}Applying fix using method: $method${NC}"
    echo ""
    
    # Create backup
    echo -e "${YELLOW}Creating backup:${NC} $BACKUP_FILE"
    cp "$CONFIG_FILE" "$BACKUP_FILE"
    
    if [ "$method" = "improved" ]; then
        # Use the pre-built improved config
        echo -e "${GREEN}Copying improved configuration...${NC}"
        cp "$IMPROVED_CONFIG" "$CONFIG_FILE"
    elif [ "$method" = "patch" ]; then
        # Apply targeted patches using yq
        echo -e "${GREEN}Applying targeted patches...${NC}"
        
        # Update low load
        yq eval '.loads[] |= (select(.name == "low") | .queryQPS = 15)' -i "$CONFIG_FILE"
        
        # Update medium load
        yq eval '.loads[] |= (select(.name == "medium") | .queryQPS = 40)' -i "$CONFIG_FILE"
        
        # Update high load
        yq eval '.loads[] |= (select(.name == "high") | .queryQPS = 80)' -i "$CONFIG_FILE"
        
        # Update very-high load
        yq eval '.loads[] |= (select(.name == "very-high") | .queryQPS = 140)' -i "$CONFIG_FILE"
        
        echo -e "${GREEN}✅ Patches applied${NC}"
    fi
    
    echo ""
    echo -e "${GREEN}✅ Configuration updated successfully!${NC}"
    echo -e "${YELLOW}Backup saved to:${NC} $BACKUP_FILE"
    echo ""
}

#
# Verify the fix
#
verify_fix() {
    echo -e "${BLUE}Verifying configuration...${NC}"
    echo ""
    
    local low_qps=$(yq eval '.loads[] | select(.name == "low") | .queryQPS' "$CONFIG_FILE")
    local med_qps=$(yq eval '.loads[] | select(.name == "medium") | .queryQPS' "$CONFIG_FILE")
    local high_qps=$(yq eval '.loads[] | select(.name == "high") | .queryQPS' "$CONFIG_FILE")
    local vhigh_qps=$(yq eval '.loads[] | select(.name == "very-high") | .queryQPS' "$CONFIG_FILE")
    
    local all_ok=true
    
    if [ "$low_qps" -eq 15 ]; then
        echo -e "${GREEN}✅${NC} low queryQPS = $low_qps (correct)"
    else
        echo -e "${RED}❌${NC} low queryQPS = $low_qps (expected 15)"
        all_ok=false
    fi
    
    if [ "$med_qps" -eq 40 ]; then
        echo -e "${GREEN}✅${NC} medium queryQPS = $med_qps (correct)"
    else
        echo -e "${RED}❌${NC} medium queryQPS = $med_qps (expected 40)"
        all_ok=false
    fi
    
    if [ "$high_qps" -eq 80 ]; then
        echo -e "${GREEN}✅${NC} high queryQPS = $high_qps (correct)"
    else
        echo -e "${RED}❌${NC} high queryQPS = $high_qps (expected 80)"
        all_ok=false
    fi
    
    if [ "$vhigh_qps" -eq 140 ]; then
        echo -e "${GREEN}✅${NC} very-high queryQPS = $vhigh_qps (correct)"
    else
        echo -e "${RED}❌${NC} very-high queryQPS = $vhigh_qps (expected 140)"
        all_ok=false
    fi
    
    echo ""
    
    if $all_ok; then
        echo -e "${GREEN}✅ All checks passed! Configuration is correct.${NC}"
        return 0
    else
        echo -e "${RED}❌ Some checks failed. Please review the configuration.${NC}"
        return 1
    fi
}

#
# Main menu
#
main() {
    # Check prerequisites
    if ! command -v yq &> /dev/null; then
        echo -e "${RED}Error: yq is not installed${NC}"
        echo "Please install yq: https://github.com/mikefarah/yq"
        exit 1
    fi
    
    if [ ! -f "$CONFIG_FILE" ]; then
        echo -e "${RED}Error: Config file not found: $CONFIG_FILE${NC}"
        exit 1
    fi
    
    # Show comparison
    show_comparison
    
    # Ask user what to do
    echo -e "${YELLOW}What would you like to do?${NC}"
    echo ""
    echo "  1) Show expected results after fix"
    echo "  2) Apply fix (copy improved config)"
    echo "  3) Apply fix (patch existing config)"
    echo "  4) Verify current config"
    echo "  5) Restore from backup"
    echo "  6) Exit"
    echo ""
    read -p "Enter choice [1-6]: " choice
    echo ""
    
    case $choice in
        1)
            show_expected_results
            echo ""
            read -p "Press Enter to continue..."
            main
            ;;
        2)
            if [ ! -f "$IMPROVED_CONFIG" ]; then
                echo -e "${RED}Error: Improved config not found: $IMPROVED_CONFIG${NC}"
                exit 1
            fi
            apply_fix "improved"
            verify_fix
            show_expected_results
            ;;
        3)
            apply_fix "patch"
            verify_fix
            show_expected_results
            ;;
        4)
            verify_fix
            ;;
        5)
            # List available backups
            echo -e "${BLUE}Available backups:${NC}"
            ls -lht "${CONFIG_FILE}.backup."* 2>/dev/null | head -10 || echo "No backups found"
            echo ""
            read -p "Enter backup file path to restore: " backup_path
            if [ -f "$backup_path" ]; then
                cp "$backup_path" "$CONFIG_FILE"
                echo -e "${GREEN}✅ Restored from $backup_path${NC}"
            else
                echo -e "${RED}❌ Backup file not found${NC}"
            fi
            ;;
        6)
            echo "Exiting..."
            exit 0
            ;;
        *)
            echo -e "${RED}Invalid choice${NC}"
            exit 1
            ;;
    esac
}

# Run main menu
main


