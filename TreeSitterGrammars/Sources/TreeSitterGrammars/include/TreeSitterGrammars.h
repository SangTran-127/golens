#ifndef TREE_SITTER_GRAMMARS_H
#define TREE_SITTER_GRAMMARS_H

#include <stdint.h>

typedef struct TSLanguage TSLanguage;

const TSLanguage *tree_sitter_json(void);
const TSLanguage *tree_sitter_yaml(void);
const TSLanguage *tree_sitter_make(void);
const TSLanguage *tree_sitter_dockerfile(void);

#endif
