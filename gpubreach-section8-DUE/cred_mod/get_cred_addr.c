/*
 * get_cred_addr.c - Kernel module to expose process cred address
 *
 * Usage:
 *   insmod get_cred_addr.ko
 *
 *   # Get current process cred
 *   cat /sys/kernel/cred_helper/euid_addr
 *
 *   # Get specific PID's cred
 *   echo 1234 > /sys/kernel/cred_helper/pid
 *   echo 1234 | sudo tee /sys/kernel/cred_helper/pid >/dev/null
 *   cat /sys/kernel/cred_helper/euid_addr
 *
 *   # Reset to current process
 *   echo 0 > /sys/kernel/cred_helper/pid
 *   echo 0 | sudo tee /sys/kernel/cred_helper/pid >/dev/null
 */

#include <linux/cred.h>
#include <linux/init.h>
#include <linux/kernel.h>
#include <linux/kobject.h>
#include <linux/module.h>
#include <linux/pid.h>
#include <linux/sched.h>
#include <linux/sched/signal.h>
#include <linux/sysfs.h>
#include <asm/io.h>
#include <linux/slab.h>

MODULE_LICENSE("GPL");
MODULE_AUTHOR("GPUBREACH-D2H Research");
MODULE_DESCRIPTION("Expose process cred structure address");

static struct kobject *cred_kobj;
static pid_t target_pid = 0; /* 0 = current process */

/* Get task_struct for target PID, or current if pid=0 */
static struct task_struct *get_target_task(void)
{
    struct task_struct *task;

    if (target_pid == 0)
    {
        return current;
    }

    rcu_read_lock();
    task = pid_task(find_vpid(target_pid), PIDTYPE_PID);
    rcu_read_unlock();

    return task;
}

/* Show/set target PID */
static ssize_t pid_show(struct kobject *kobj, struct kobj_attribute *attr, char *buf)
{
    if (target_pid == 0)
    {
        return sprintf(buf, "0 (current process)\n");
    }
    return sprintf(buf, "%d\n", target_pid);
}

static ssize_t pid_store(struct kobject *kobj, struct kobj_attribute *attr, const char *buf, size_t count)
{
    int ret;
    pid_t pid;

    ret = kstrtoint(buf, 10, &pid);
    if (ret)
        return ret;

    if (pid < 0)
        return -EINVAL;

    target_pid = pid;
    pr_info("[CRED-HELPER] Target PID set to %d\n", target_pid);

    return count;
}

/* Show cred structure address */
static ssize_t cred_addr_show(struct kobject *kobj, struct kobj_attribute *attr, char *buf)
{
    struct task_struct *task = get_target_task();
    const struct cred *cred;

    if (!task)
    {
        pr_err("[CRED-HELPER] PID %d not found\n", target_pid);
        return sprintf(buf, "ERROR: PID %d not found\n", target_pid);
    }

    cred = __task_cred(task);
    pr_info("[CRED-HELPER] PID %d: cred = 0x%px\n", target_pid ? target_pid : current->pid, cred);

    return sprintf(buf, "0x%px\n", cred);
}

/* Show euid address (cred + offsetof(struct cred, euid)) */
static ssize_t euid_addr_show(struct kobject *kobj, struct kobj_attribute *attr, char *buf)
{
    struct task_struct *task = get_target_task();
    const struct cred *cred;
    const void *euid_addr;

    if (!task)
    {
        pr_err("[CRED-HELPER] PID %d not found\n", target_pid);
        return sprintf(buf, "ERROR: PID %d not found\n", target_pid);
    }

    cred = __task_cred(task);
    euid_addr = &cred->euid;

    phys_addr_t pa = virt_to_bus((void *)euid_addr);
    phys_addr_t p1 = virt_to_phys((void *)euid_addr);
    phys_addr_t rev_pa = phys_to_virt(p1);

    pr_info("Bus Address: %pa\n", &pa);
    pr_info("Phys Address: %pa\n", &p1);
    pr_info("Reverse Physical Address: %pa\n", &rev_pa);

    pr_info("[CRED-HELPER] PID %d: euid address (TARGET) = 0x%px\n", target_pid ? target_pid : current->pid,
            euid_addr);
    pr_info("[CRED-HELPER] PID %d: current euid value = %u\n", target_pid ? target_pid : current->pid,
            __kuid_val(cred->euid));

    return sprintf(buf, "0x%px\n", (void*)pa);
}

/* Show uid address */
static ssize_t uid_addr_show(struct kobject *kobj, struct kobj_attribute *attr, char *buf)
{
    struct task_struct *task = get_target_task();
    const struct cred *cred;
    const void *uid_addr;

    if (!task)
    {
        pr_err("[CRED-HELPER] PID %d not found\n", target_pid);
        return sprintf(buf, "ERROR: PID %d not found\n", target_pid);
    }

    cred = __task_cred(task);
    uid_addr = &cred->uid;

    pr_info("[CRED-HELPER] PID %d: uid address = 0x%px\n", target_pid ? target_pid : current->pid, uid_addr);

    return sprintf(buf, "0x%px\n", uid_addr);
}

/* Show current uid/euid values */
static ssize_t current_ids_show(struct kobject *kobj, struct kobj_attribute *attr, char *buf)
{
    struct task_struct *task = get_target_task();
    const struct cred *cred;

    if (!task)
    {
        pr_err("[CRED-HELPER] PID %d not found\n", target_pid);
        return sprintf(buf, "ERROR: PID %d not found\n", target_pid);
    }

    cred = __task_cred(task);

    pr_info("[CRED-HELPER] PID %d: uid=%u euid=%u gid=%u egid=%u\n", target_pid ? target_pid : current->pid,
            __kuid_val(cred->uid), __kuid_val(cred->euid), __kgid_val(cred->gid), __kgid_val(cred->egid));

    return sprintf(buf, "uid=%u euid=%u gid=%u egid=%u\n", __kuid_val(cred->uid), __kuid_val(cred->euid),
                   __kgid_val(cred->gid), __kgid_val(cred->egid));
}

/* Show struct cred offsets */
static ssize_t cred_offsets_show(struct kobject *kobj, struct kobj_attribute *attr, char *buf)
{
    return sprintf(buf,
                   "offsetof(struct cred, uid)  = 0x%lx\n"
                   "offsetof(struct cred, euid) = 0x%lx\n"
                   "offsetof(struct cred, gid)  = 0x%lx\n"
                   "offsetof(struct cred, egid) = 0x%lx\n"
                   "sizeof(struct cred) = %lu\n",
                   offsetof(struct cred, uid), offsetof(struct cred, euid), offsetof(struct cred, gid),
                   offsetof(struct cred, egid), sizeof(struct cred));
}

static struct kobj_attribute pid_attr = __ATTR_RW(pid);
static struct kobj_attribute cred_addr_attr = __ATTR_RO(cred_addr);
static struct kobj_attribute euid_addr_attr = __ATTR_RO(euid_addr);
static struct kobj_attribute uid_addr_attr = __ATTR_RO(uid_addr);
static struct kobj_attribute current_ids_attr = __ATTR_RO(current_ids);
static struct kobj_attribute cred_offsets_attr = __ATTR_RO(cred_offsets);

static struct attribute *cred_attrs[] = {
    &pid_attr.attr,
    &cred_addr_attr.attr,
    &euid_addr_attr.attr,
    &uid_addr_attr.attr,
    &current_ids_attr.attr,
    &cred_offsets_attr.attr,
    NULL,
};

static struct attribute_group cred_attr_group = {
    .attrs = cred_attrs,
};

static int __init cred_helper_init(void)
{
    int ret;

    pr_info("[CRED-HELPER] Loading module\n");

    /* Create /sys/kernel/cred_helper */
    cred_kobj = kobject_create_and_add("cred_helper", kernel_kobj);
    if (!cred_kobj)
    {
        pr_err("[CRED-HELPER] Failed to create kobject\n");
        return -ENOMEM;
    }

    /* Create sysfs files */
    ret = sysfs_create_group(cred_kobj, &cred_attr_group);
    if (ret)
    {
        pr_err("[CRED-HELPER] Failed to create sysfs group\n");
        kobject_put(cred_kobj);
        return ret;
    }

    pr_info("[CRED-HELPER] Module loaded successfully\n");
    pr_info("[CRED-HELPER] Usage:\n");
    pr_info("[CRED-HELPER]   # Current process:\n");
    pr_info("[CRED-HELPER]   cat /sys/kernel/cred_helper/euid_addr\n");
    pr_info("[CRED-HELPER]   # Specific PID:\n");
    pr_info("[CRED-HELPER]   echo <PID> > /sys/kernel/cred_helper/pid\n");
    pr_info("[CRED-HELPER]   cat /sys/kernel/cred_helper/euid_addr\n");
    pr_info("[CRED-HELPER]   # Check dmesg again for printk output\n");

    return 0;
}

static void __exit cred_helper_exit(void)
{
    pr_info("[CRED-HELPER] Unloading module\n");
    sysfs_remove_group(cred_kobj, &cred_attr_group);
    kobject_put(cred_kobj);
}

module_init(cred_helper_init);
module_exit(cred_helper_exit);