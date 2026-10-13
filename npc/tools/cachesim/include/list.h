#ifndef __LIST_H__
#define __LIST_H__

typedef struct Node {
    void *data;
    struct Node *next;
    struct Node *prev;
} Node;

typedef struct {
    Node *head;
    Node *tail;
    unsigned int length;
} List;

// LIST_FOREACH(list, start_node, next/prev, current node)
#define LIST_FOREACH(L, S, M, V)\
    for(Node *V = L->S, *_node = L->S; _node != NULL; V = _node = _node->M)
    
List *list_create();
void list_enqueue(List *list, void *data);
void list_pop(List *list);
void list_destroy(List *list);
    
#endif
