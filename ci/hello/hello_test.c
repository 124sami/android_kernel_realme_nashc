#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/init.h>
#include <linux/proc_fs.h>
#include <linux/string.h>

/* Imports a few of the symbols that were trimmed out of the stock build
 * (memset, strcmp, proc_create ...) so loading this module proves they are
 * exported again. */
static struct proc_dir_entry *ent;

static int __init hello_init(void)
{
	char buf[8];

	memset(buf, 0, sizeof(buf));
	strcpy(buf, "ok");
	ent = proc_create("hello_test", 0444, NULL, NULL);
	pr_info("hello_test: loaded OK (%s)\n", strcmp(buf, "ok") ? "bad" : "good");
	return 0;
}

static void __exit hello_exit(void)
{
	if (ent)
		remove_proc_entry("hello_test", NULL);
	pr_info("hello_test: unloaded\n");
}

module_init(hello_init);
module_exit(hello_exit);
MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("nashc module-loading smoke test");
