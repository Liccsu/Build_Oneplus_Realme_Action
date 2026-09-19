#!/usr/bin/env bash
#
# apply-local-fixes.sh —— 在 SukiSU-Ultra(builtin) + SUSFS 构建流程里做三处本地修补
#
#   1) static_key 类型混用：SUSFS 的 50_ 补丁把 SukiSU 的 bool 变量当 struct static_key_true 用
#   2) 补上 SukiSU 未实现的 ksu_handle_post_execveat_sucompat（SUSFS 的 fs/exec.c 引用它）
#   3) 全程无静默路径：无法判定 / 替换不完整 / 注入失败 都硬失败
#
# 用法: apply-local-fixes.sh <COMMON_DIR> <KERNELSU_DIR>
#   COMMON_DIR   内核源码根（含 fs/ drivers/），例：kernel_workspace/common
#   KERNELSU_DIR KernelSU 源码根（含 kernel/feature/），例：kernel_workspace/KernelSU
#
# 设计说明：这里刻意用「按模式命中」而不是 .patch —— 上游 SukiSU 是活跃项目，
# patch 的 hunk 上下文一变就失效，而模式匹配只关心目标那一行。

set -uo pipefail   # 不启用 -e：grep 无匹配返回 1 属正常路径

COMMON_DIR="${1:?用法: $0 <COMMON_DIR> <KERNELSU_DIR>}"
KERNELSU_DIR="${2:?用法: $0 <COMMON_DIR> <KERNELSU_DIR>}"

note() { echo "[fix] $*"; }
fail() { echo "::error::$*"; exit 1; }

[ -d "$COMMON_DIR" ]   || fail "COMMON_DIR 不存在: $COMMON_DIR"
[ -d "$KERNELSU_DIR" ] || fail "KERNELSU_DIR 不存在: $KERNELSU_DIR"
cd "$COMMON_DIR" || fail "无法进入 $COMMON_DIR"

# ---------------------------------------------------------------------------
# [1] static_key 类型混用修正
#
# 50_ 补丁在下列文件里以 `extern struct static_key_true X;` + `static_branch_*(&X)`
# 使用这些变量。SukiSU 侧的真实类型必须逐条判定：
#     ksu_su_compat_enabled       -> bool（sucompat.c: bool ksu_su_compat_enabled __read_mostly = true;）
#     ksu_is_init_rc_hook_enabled -> DEFINE_STATIC_KEY_TRUE（runtime/ksud.c）
#     ksu_is_input_hook_enabled   -> DEFINE_STATIC_KEY_TRUE（runtime/ksud.c）
# 把 bool 当 static_key 解引用是 UB（static_branch_* 会回写该变量、破坏取值）；
# 而把真正的 static_key 当裸变量用同样是错的。因此：
#   - 判定为 bool        -> 内核侧退化为裸变量判断
#   - 判定为 static_key  -> 保持原样
#   - 两者都判不出        -> 硬失败（不猜）
# ---------------------------------------------------------------------------
fix_var() {
    local v="$1"; shift
    echo "===== $v ====="
    grep -rn "$v" "$KERNELSU_DIR/kernel/" 2>/dev/null | head -n 3 || true

    local kind=""
    if grep -rqE "bool[[:space:]]+$v([[:space:]]|;|=|$)" "$KERNELSU_DIR/kernel/"; then
        kind="bool"
    elif grep -rqE "DEFINE_STATIC_KEY(_TRUE)?[[:space:]]*\([[:space:]]*$v([[:space:]]|,|\))" "$KERNELSU_DIR/kernel/";
then
        kind="skey"
    else
        fail "$v 在 SukiSU 侧既不是 bool 也不是 DEFINE_STATIC_KEY_TRUE —— 判定假设不成立，请人工核对该变量"
    fi
    note "判定: $v -> $kind"

    if [ "$kind" = "skey" ]; then
        note "[keep] $v 是真正的 static_key，保持 static_branch_* 原样（不动内核侧）"
        return 0
    fi

    local f before after
    for f in "$@"; do
        [ -f "$f" ] || fail "$f 不存在（预期应被 50_ 补丁修改）"

        before=$(grep -cE "static_branch_(likely|unlikely)\(&$v\)" "$f" || true)
        sed -i "s/extern struct static_key_true $v;/extern bool $v;/" "$f"
        sed -i "s/static_branch_likely(&$v)/($v)/g; s/static_branch_unlikely(&$v)/($v)/g" "$f"
        after=$(grep -cE "static_branch_(likely|unlikely)\(&$v\)" "$f" || true)

        if [ "$before" -gt 0 ] && [ "$after" -ne 0 ]; then
            fail "$f 替换不完整：static_branch_*(&$v) 由 $before 处变为 $after 处"
        fi
        note "[ok] $f  （$before -> $after）"
    done
}

fix_var ksu_su_compat_enabled       fs/exec.c fs/open.c fs/stat.c

# ---------------------------------------------------------------------------
# [1b] 为 SukiSU 已移除、但 SUSFS 补丁仍引用的两个 hook 开关提供 stub 定义
#
# main 分支已移除 init_rc / input_hook 功能（kernel/feature/ 下无对应文件，
# runtime/ksud.c 中也不再有这两个变量），而 50_ 补丁仍以 static_key 形式引用：
#     extern struct static_key_true ksu_is_init_rc_hook_enabled;
#     if (static_branch_unlikely(&ksu_is_init_rc_hook_enabled))
#         ksu_handle_sys_read(fd);
# 缺定义会在链接期报 undefined symbol。
#
# 这里注入 DEFINE_STATIC_KEY_FALSE：分支被编译期消除，符号同时得到满足，
# 行为等价于「该 hook 未启用」，与 main 移除这两个功能后的状态一致。
# 注意不能用 DEFINE_STATIC_KEY_TRUE —— 那会让内核去调用 ksu_handle_sys_read /
# ksu_handle_vfs_fstat，而它们在 main 上同样不存在。
# ---------------------------------------------------------------------------
INJECT_KEY_C="$KERNELSU_DIR/kernel/feature/sucompat.c"
[ -f "$INJECT_KEY_C" ] || fail "未找到 $INJECT_KEY_C"

inject_disabled_key() {
    local v="$1"

    if grep -rqE "DEFINE_STATIC_KEY_(TRUE|FALSE)[[:space:]]*\([[:space:]]*$v([[:space:]]|,|\))" \
         "$KERNELSU_DIR/kernel/"; then
        note "[skip] $v 已有 DEFINE_STATIC_KEY_* 定义"
        return 0
    fi

    if ! grep -q 'linux/jump_label.h' "$INJECT_KEY_C"; then
        sed -i '1i #include <linux/jump_label.h>' "$INJECT_KEY_C"
    fi

    printf '\n#ifdef CONFIG_KSU_SUSFS\nDEFINE_STATIC_KEY_FALSE(%s);\n#endif\n' "$v" \
        >> "$INJECT_KEY_C"

    grep -q "DEFINE_STATIC_KEY_FALSE($v)" "$INJECT_KEY_C" || fail "注入 $v 失败"
    note "[ok] 已注入 $v (FALSE) -> $INJECT_KEY_C"
}

inject_disabled_key ksu_is_init_rc_hook_enabled
inject_disabled_key ksu_is_input_hook_enabled

# ---------------------------------------------------------------------------
# [1c] 50_ 补丁引用、而 main 上无法链接的函数：
#     ksu_handle_sys_read   —— main 里是 static 且签名不同
#     ksu_handle_vfs_fstat  —— main 里完全没有
#     ksu_handle_sys_reboot —— main 里完全没有。该调用点未被任何 key 守护，
#         补丁里的调用形式是：
#             ret = ksu_handle_sys_reboot(magic1, magic2, cmd, &arg);
#             if (ret) { goto orig_flow; }
#             return ret;
#         即返回 0 会被视为"已由 KSU 处理完毕"而直接返回，reboot 静默失效；
#         必须返回非 0（用 -ENOSYS）才会跳回原生 reboot 流程。
# 签名必须与 50_ 补丁里的 extern 声明逐字一致。
# 其余被引用的 ksu_* 符号（input_handle_event、execveat、execveat_sucompat、
# faccessat、setresuid、stat、__ksu_is_allow_uid_for_current、
# ksu_selinux_hide_*）在 main 上均有非 static 定义，无需处理。
# ---------------------------------------------------------------------------
inject_stub_fn() {
    local decl="$1"
    local body="${2:-}"
    local name
    name=$(printf '%s' "$decl" | sed -n 's/^[a-zA-Z_][a-zA-Z_0-9]*[[:space:]]*\([a-zA-Z_][a-zA-Z_0-9]*\)[[:space:]]*(.*/\1/p')
    [ -n "$name" ] || fail "无法从声明中解析函数名: $decl"

    if grep -qE "(^|[^a-zA-Z_0-9])${name}[[:space:]]*\(" "$INJECT_KEY_C"; then
        note "[skip] $name 已存在"
        return 0
    fi

    if [ -n "$body" ]; then
        printf '\n#ifdef CONFIG_KSU_SUSFS\n%s\n{\n\t%s\n}\n#endif\n' "$decl" "$body" >> "$INJECT_KEY_C"
    else
        printf '\n#ifdef CONFIG_KSU_SUSFS\n%s\n{\n}\n#endif\n' "$decl" >> "$INJECT_KEY_C"
    fi
    grep -q "${name}(" "$INJECT_KEY_C" || fail "注入 $name 失败"
    note "[ok] 已注入 $name -> $INJECT_KEY_C"
}

inject_stub_fn 'void ksu_handle_sys_read(unsigned int fd)'
inject_stub_fn 'void ksu_handle_vfs_fstat(int fd, loff_t *kstat_size_ptr)'
inject_stub_fn 'int ksu_handle_sys_reboot(int magic1, int magic2, unsigned int cmd, void __user **arg)' 'return -ENOSYS;'

echo "--- static_key 自检（应只剩 extern bool 与裸变量判断）---"
sed -n '/ksu_su_compat_enabled/p;/ksu_is_init_rc_hook_enabled/p;/ksu_is_input_hook_enabled/p' \
    fs/exec.c fs/open.c fs/stat.c fs/read_write.c drivers/input/input.c 2>/dev/null || true

# ---------------------------------------------------------------------------
# [2] 注入 ksu_handle_post_execveat_sucompat
#
# SUSFS 的 50_ 补丁在 fs/exec.c 的 do_execveat_common() 里引用该符号，而
# SukiSU-Ultra 的 builtin 分支没有实现它（该符号属 ReSukiSU），链接期会报：
#     ld.lld: error: undefined symbol: ksu_handle_post_execveat_sucompat
# 上游 KernelPatch 的 10_ 补丁里该函数调用 ksu_install_su_fd()，而 SukiSU 没有
# 这个符号，所以这里用纯 return 0：只丢掉「execve 成功后给当前进程装 su 会话 fd」
# 这一小块，SUS_PATH / SUS_MOUNT / SUS_KSTAT / SUS_MAP 等隐藏不受影响。
#
# 不需要改 sucompat.h：fs/exec.c 的补丁自带 extern 声明，树里存在非 static 定义
# 即可解析；而 sucompat.h 末尾是 #endif，append 声明会落到 #endif 之后而失效。
# ---------------------------------------------------------------------------
SUCOMPAT_C="$KERNELSU_DIR/kernel/feature/sucompat.c"
[ -f "$SUCOMPAT_C" ] || fail "未找到 $SUCOMPAT_C"

if grep -q 'ksu_handle_post_execveat_sucompat' "$SUCOMPAT_C"; then
    note "[skip] ksu_handle_post_execveat_sucompat 已存在"
else
    printf '\n#ifdef CONFIG_KSU_SUSFS\nint ksu_handle_post_execveat_sucompat(int *fd, struct filename
**filename_ptr,\n\t\t\t\t      void *argv_user, void *envp_user,\n\t\t\t\t      int *__never_use_flags, int
*retval)\n{\n\treturn 0;\n}\n#endif\n' >> "$SUCOMPAT_C"
    grep -q 'ksu_handle_post_execveat_sucompat' "$SUCOMPAT_C" \
        || fail "注入 ksu_handle_post_execveat_sucompat 失败"
    note "[ok] 已注入 ksu_handle_post_execveat_sucompat -> $SUCOMPAT_C"
fi
grep -n 'ksu_handle_post_execveat_sucompat' "$SUCOMPAT_C" || true

echo
echo "[fix] 本地修补全部完成（无未生效项）"
exit 0