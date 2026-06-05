/* mz_os.c -- System functions
   part of the minizip-ng project

   Copyright (C) Nathan Moinvaziri
     https://github.com/zlib-ng/minizip-ng
   Copyright (C) 1998-2010 Gilles Vollant
     https://www.winimage.com/zLibDll/minizip.html

   This program is distributed under the terms of the same license as zlib.
   See the accompanying LICENSE file for the full text of the license.
*/

#include "mz.h"
#include "mz_crypt.h"
#include "mz_os.h"
#include "mz_strm.h"
#include "mz_strm_os.h"

#include <ctype.h> /* tolower */
#include <string.h>

/***************************************************************************/

int32_t mz_path_combine(char *path, const char *join, int32_t max_path) {
    int32_t path_len = 0;

    if (!path || !join || !max_path)
        return MZ_PARAM_ERROR;

    path_len = (int32_t)strlen(path);

    if (path_len == 0) {
        strncpy(path, join, max_path - 1);
        path[max_path - 1] = 0;
    } else {
        mz_path_append_slash(path, max_path, MZ_PATH_SLASH_PLATFORM);
        path_len = (int32_t)strlen(path);
        if (max_path > path_len)
            strncat(path, join, max_path - path_len - 1);
    }

    return MZ_OK;
}

int32_t mz_path_append_slash(char *path, int32_t max_path, char slash) {
    int32_t path_len = (int32_t)strlen(path);
    if ((path_len + 2) >= max_path)
        return MZ_BUF_ERROR;
    if (!mz_os_is_dir_separator(path[path_len - 1])) {
        path[path_len] = slash;
        path[path_len + 1] = 0;
    }
    return MZ_OK;
}

int32_t mz_path_remove_slash(char *path) {
    int32_t path_len = (int32_t)strlen(path);
    while (path_len > 0) {
        if (mz_os_is_dir_separator(path[path_len - 1]))
            path[path_len - 1] = 0;
        else
            break;

        path_len -= 1;
    }
    return MZ_OK;
}

int32_t mz_path_has_slash(const char *path) {
    int32_t path_len = (int32_t)strlen(path);
    if (path_len > 0 && !mz_os_is_dir_separator(path[path_len - 1]))
        return MZ_EXIST_ERROR;
    return MZ_OK;
}

int32_t mz_path_convert_slashes(char *path, char slash) {
    int32_t i = 0;

    for (i = 0; i < (int32_t)strlen(path); i += 1) {
        if (mz_os_is_dir_separator(path[i]))
            path[i] = slash;
    }
    return MZ_OK;
}

int32_t mz_path_compare_wc(const char *path, const char *wildcard, uint8_t ignore_case) {
    while (*path != 0) {
        switch (*wildcard) {
        case '*':

            if (*(wildcard + 1) == 0)
                return MZ_OK;

            while (*path != 0) {
                if (mz_path_compare_wc(path, (wildcard + 1), ignore_case) == MZ_OK)
                    return MZ_OK;

                path += 1;
            }

            return MZ_EXIST_ERROR;

        default:
            /* Ignore differences in path slashes on platforms */
            if ((*path == '\\' && *wildcard == '/') || (*path == '/' && *wildcard == '\\'))
                break;

            if (ignore_case) {
                if (tolower(*path) != tolower(*wildcard))
                    return MZ_EXIST_ERROR;
            } else {
                if (*path != *wildcard)
                    return MZ_EXIST_ERROR;
            }

            break;
        }

        path += 1;
        wildcard += 1;
    }

    if ((*wildcard != 0) && (*wildcard != '*'))
        return MZ_EXIST_ERROR;

    return MZ_OK;
}

int32_t mz_path_resolve(const char *path, char *output, int32_t max_output) {
    const char *source = path;
    const char *check = output;
    char *target = output;

    if (max_output <= 0)
        return MZ_PARAM_ERROR;

    while (*source != 0 && max_output > 1) {
        check = source;
        if (mz_os_is_dir_separator(*check))
            check += 1;

        if (source == path || target == output || check != source) {
            /* Skip double paths */
            if (mz_os_is_dir_separator(*check)) {
                source += 1;
                continue;
            }
            if (*check == '.') {
                check += 1;

                /* Remove . if at end of string and not at the beginning */
                if (*check == 0 && source != path && target != output) {
                    /* Copy last slash */
                    *target = *source;
                    target += 1;
                    max_output -= 1;
                    source += (check - source);
                    continue;
                }
                /* Remove . if not at end of string */
                else if (mz_os_is_dir_separator(*check)) {
                    source += (check - source);
                    /* Skip slash if at beginning of string */
                    if (target == output && *source != 0)
                        source += 1;
                    continue;
                }
                /* Go to parent directory .. */
                else if (*check == '.') {
                    check += 1;
                    if (*check == 0 || mz_os_is_dir_separator(*check)) {
                        source += (check - source);

                        /* Search backwards for previous slash or the start of the output string */
                        if (target != output) {
                            target -= 1;
                            do {
                                if (target == output || mz_os_is_dir_separator(*target))
                                    break;

                                target -= 1;
                                max_output += 1;
                            } while (target > output);
                        }

                        if ((target == output) && *source != 0)
                            source += 1;
                        if (mz_os_is_dir_separator(*target) && *source == 0)
                            target += 1;

                        *target = 0;
                        continue;
                    }
                }
            }
        }

        *target = *source;

        source += 1;
        target += 1;
        max_output -= 1;
    }

    *target = 0;

    if (*path == 0)
        return MZ_INTERNAL_ERROR;

    return MZ_OK;
}

int32_t mz_path_remove_filename(char *path) {
    char *path_ptr = NULL;

    if (!path)
        return MZ_PARAM_ERROR;

    path_ptr = path + strlen(path) - 1;

    while (path_ptr > path) {
        if (mz_os_is_dir_separator(*path_ptr)) {
            *path_ptr = 0;
            break;
        }

        path_ptr -= 1;
    }

    if (path_ptr == path)
        *path_ptr = 0;

    return MZ_OK;
}

int32_t mz_path_remove_extension(char *path) {
    char *path_ptr = NULL;

    if (!path)
        return MZ_PARAM_ERROR;

    path_ptr = path + strlen(path) - 1;

    while (path_ptr > path) {
        if (mz_os_is_dir_separator(*path_ptr))
            break;
        if (*path_ptr == '.') {
            *path_ptr = 0;
            break;
        }

        path_ptr -= 1;
    }

    if (path_ptr == path)
        *path_ptr = 0;

    return MZ_OK;
}

int32_t mz_path_get_filename(const char *path, const char **filename) {
    const char *match = NULL;

    if (!path || !filename)
        return MZ_PARAM_ERROR;

    *filename = NULL;

    for (match = path; *match != 0; match += 1) {
        if (mz_os_is_dir_separator(*match))
            *filename = match + 1;
    }

    if (!*filename)
        return MZ_EXIST_ERROR;

    return MZ_OK;
}

int32_t mz_dir_has_unsafe_symlink(const char *path, const char *base_path) {
    char *check_path = NULL;
    char *symlink_target = NULL;
    char *combined = NULL;
    char *resolved = NULL;
    size_t path_len = 0;
    size_t base_len = 0;
    size_t max_path = 1024;
    size_t parent_len = 0;
    size_t pos = 0;
    size_t cmp_len = 0;
    int32_t err = MZ_OK;

    if (!path || *path == 0 || !base_path)
        return MZ_PARAM_ERROR;

    path_len = strlen(path);
    base_len = strlen(base_path);

    /* Remove trailing slash from base_path for comparison */
    while (base_len > 0 && mz_os_is_dir_separator(base_path[base_len - 1]))
        base_len--;

    check_path = (char *)calloc(1, path_len + 1);
    if (!check_path)
        return MZ_MEM_ERROR;

    /* Walk through each path component */
    while (err == MZ_OK && pos < path_len) {
        /* Copy separator if present */
        if (mz_os_is_dir_separator(path[pos])) {
            check_path[pos] = path[pos];
            pos++;
        }

        /* Copy next path component */
        while (pos < path_len && !mz_os_is_dir_separator(path[pos])) {
            check_path[pos] = path[pos];
            pos++;
        }
        check_path[pos] = 0;

        /* Check if this existing path component is a symlink */
        if (mz_os_is_symlink(check_path) != MZ_OK)
            continue;

        /* Skip components at or above the base dir. */
        cmp_len = pos;
        if (mz_path_has_slash(check_path) == MZ_OK)
            cmp_len--;
        if (cmp_len <= base_len && strncmp(check_path, base_path, cmp_len) == 0) {
            /* Verify that the prefix match is on a directory boundary. */
            if (cmp_len == base_len || mz_os_is_dir_separator(base_path[cmp_len]))
                continue;
        }

        /* Allocate symlink buffers on first use */
        if (!symlink_target) {
            symlink_target = (char *)calloc(1, max_path);
            combined = (char *)calloc(1, max_path);
            resolved = (char *)calloc(1, max_path);

            if (!symlink_target || !combined || !resolved) {
                err = MZ_MEM_ERROR;
                break;
            }
        }

        if (mz_os_read_symlink(check_path, symlink_target, max_path) != MZ_OK) {
            err = MZ_EXIST_ERROR;
            break;
        }

        /* Absolute symlink targets are not allowed */
        if (mz_os_is_dir_separator(symlink_target[0])) {
            err = MZ_EXIST_ERROR;
            break;
        }

        /* Find parent directory length by scanning backwards past filename and trailing slashes */
        parent_len = pos;
        while (parent_len > 0 && !mz_os_is_dir_separator(check_path[parent_len - 1]))
            parent_len--;
        while (parent_len > 0 && mz_os_is_dir_separator(check_path[parent_len - 1]))
            parent_len--;

        /* Combine parent + symlink_target */
        combined[0] = 0;
        if (parent_len > 0) {
            strncpy(combined, check_path, parent_len);
            combined[parent_len] = 0;
            mz_path_append_slash(combined, (int32_t)max_path, MZ_PATH_SLASH_PLATFORM);
        }
        strncat(combined, symlink_target, max_path - strlen(combined) - 1);

        /* Resolve the combined path to eliminate .. */
        if (mz_path_resolve(combined, resolved, (int32_t)max_path) != MZ_OK) {
            err = MZ_EXIST_ERROR;
            break;
        }

        /* Check that resolved path starts with base_path */
        if (strlen(resolved) < base_len ||
            strncmp(resolved, base_path, base_len) != 0 ||
            (resolved[base_len] != 0 && !mz_os_is_dir_separator(resolved[base_len]))) {
            err = MZ_EXIST_ERROR;
            break;
        }
    }

    free(check_path);
    free(symlink_target);
    free(combined);
    free(resolved);

    return err;
}

int32_t mz_dir_make(const char *path) {
    int32_t err = MZ_OK;
    char *current_dir = NULL;
    char *match = NULL;
    char hold = 0;

    if (!*path)
        return MZ_OK;

    current_dir = strdup(path);
    if (!current_dir)
        return MZ_MEM_ERROR;

    mz_path_remove_slash(current_dir);

    err = mz_os_make_dir(current_dir);
    if (err != MZ_OK) {
        match = current_dir + 1;
        while (1) {
            while (*match != 0 && !mz_os_is_dir_separator(*match))
                match += 1;
            hold = *match;
            *match = 0;

            err = mz_os_make_dir(current_dir);
            if (err != MZ_OK)
                break;
            if (hold == 0)
                break;

            *match = hold;
            match += 1;
        }
    }

    free(current_dir);
    return err;
}

int32_t mz_file_get_crc(const char *path, uint32_t *result_crc) {
    void *stream = NULL;
    uint32_t crc32 = 0;
    int32_t read = 0;
    int32_t err = MZ_OK;
    uint8_t buf[16384];

    stream = mz_stream_os_create();
    if (!stream)
        return MZ_MEM_ERROR;

    err = mz_stream_os_open(stream, path, MZ_OPEN_MODE_READ);
    if (err == MZ_OK) {
        do {
            read = mz_stream_os_read(stream, buf, sizeof(buf));

            if (read < 0) {
                err = read;
                break;
            }

            crc32 = mz_crypt_crc32_update(crc32, buf, read);
        } while ((err == MZ_OK) && (read > 0));

        mz_stream_os_close(stream);
    }

    *result_crc = crc32;

    mz_stream_os_delete(&stream);

    return err;
}

/***************************************************************************/
