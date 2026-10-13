#ifndef _stack_h_
#define _stack_h_

typedef struct Stack_Node {
    struct Stack_Node *prev;
    void *value;
} Stack_Node;

typedef struct Stack {
    int count;
    Stack_Node *top;
    Stack_Node *bottom;
} Stack;

#define Stack_empty(stack) (stack->bottom == NULL ? 1 : 0)
#define Stack_create() (Stack *)calloc(1, sizeof(Stack))
#define Stack_peek(stack) (stack->top ? stack->top->value : NULL)
#define Stack_push(stack, data) do { \
    Stack_Node *node = (Stack_Node *)calloc(1, sizeof(Stack_Node)); \
    node->value = data; \
    if (stack->bottom == NULL) { \
        stack->bottom = node; \
        stack->top = node; \
    } else { \
        node->prev = stack->top; \
        stack->top = node; \
    } \
    stack->count++; \
} while(0)
#define Stack_pop(stack) stack->top->value; do { \
    Stack_Node *tmp = stack->top; \
    if (stack->top->prev != NULL) { \
        stack->top = stack->top->prev; \
    } else { \
        stack->bottom = NULL; \
        stack->top = NULL; \
    } \
    stack->count--; \
    free(tmp); \
} while(0)
#define Stack_destroy(stack) do { \
    int __cnt__ = Stack_count(stack); \
    for (int i = 0; i < __cnt__; i++) { \
        (void)Stack_pop(stack); \
    } \
    free(stack); \
    stack = NULL; \
} while(0)
#define Stack_count(stack) (stack->count)
#define STACK_FOREACH(stack, cur)  \
    for (Stack_Node *cur = stack->top; cur != NULL; cur = cur->prev)

#endif
