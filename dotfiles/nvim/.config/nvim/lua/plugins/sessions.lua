return {
    "rmagatti/auto-session",
    config = function()
        -- Exclude terminal from session options
        vim.o.sessionoptions = "blank,buffers,curdir,folds,help,tabpages,winsize,winpos,localoptions"

        require("auto-session").setup({
            log_dir = vim.fn.stdpath("data") .. "/logs",
            log_level = "error",

            auto_session_enable_last_session = false,
            auto_session_root_dir = vim.fn.stdpath("data") .. "/sessions/",
            auto_session_enabled = true,
            auto_save_enabled = true,
            auto_restore_enabled = false,
            auto_session_use_git_branch = true,

            auto_session_suppressed_dirs = { "~/", "~/Downloads", "/" },

            -- Close terminal buffers before saving session
            pre_save_cmds = {
                function()
                    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
                        if vim.bo[buf].buftype == "terminal" then
                            vim.api.nvim_buf_delete(buf, { force = true })
                        end
                    end
                end
            },

            -- Session lens disabled since we don't have telescope
            -- Use auto-session's native session management commands instead
        })
    end,
}
