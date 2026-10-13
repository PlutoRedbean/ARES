#include <list.h>
#include <stdlib.h>
#include <dbg.h>

inline int is_empty(List *list) {
  return !(list->head);
}

List *list_create() {
  List *list = malloc(sizeof(List));
  Assert(list, "Fail to create list");
  list->head = NULL;
  list->tail = NULL;
  list->length = 0;

  return list;
}

void list_enqueue(List *list, void *data) {
  Node *node = malloc(sizeof(Node));
  Assert(list, "Fail to create node");
  node->data = data;
  if (is_empty(list)) {
    node->next = NULL;
    node->prev = NULL;
    list->head = node;
    list->tail = node;
  } else {
    node->next = list->head;
    node->prev = NULL;
    list->head->prev = node;
    list->head = node;
  }
  list->length++;
}

void list_pop(List *list) {
  if (is_empty(list)) return;
  
  Node *old_tail = list->tail;
    if (list->head == list->tail) {
        list->head = NULL;
        list->tail = NULL;
    } else {
        list->tail = old_tail->prev;
        list->tail->next = NULL;
    }

    free(old_tail);
    list->length--;
}

void list_destroy(List *list) {
  if (list == NULL) return;

  Node *cur = list->head;
  Node *next_node = NULL;
  
  while (cur != NULL) {
    next_node = cur->next;
    free(cur);
    cur = next_node;
  }
    
  free(list);
  list = NULL;
}
