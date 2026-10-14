/* FinSH config file */

#ifndef __MSH_CFG_H__
#define __MSH_CFG_H__

// <<< Use Configuration Wizard in Context Menu >>>
#define RT_USING_FINSH
#define FINSH_USING_MSH
#define FINSH_USING_MSH_ONLY
// <h>FinSH Configuration
// <o>the priority of finsh thread <1-30>
//  <i>the priority of finsh thread
//  <i>Default: 21
#ifndef FINSH_THREAD_PRIORITY
#define FINSH_THREAD_PRIORITY       21
#endif
// <o>the stack of finsh thread <1-4096>
//  <i>the stack of finsh thread
//  <i>Default: 4096  (4096Byte)
#ifndef FINSH_THREAD_STACK_SIZE
#define FINSH_THREAD_STACK_SIZE     1024
#endif

#define FINSH_USING_SYMTAB
// <c1>Enable command description
//  <i>Enable command description
#define FINSH_USING_DESCRIPTION
//  </c>
// </h>

// <<< end of configuration section >>>
#endif
