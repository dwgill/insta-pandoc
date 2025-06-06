--[[
Instapaper delimits its stories within a epub with span elements with an id="story0.html" etc.
]]
local function element_is_insta_section_delimiter(el)
    return (
        el.t == 'Para' and el.content and #el.content == 1 and el.content[1].t == 'Span' and
        el.content[1].attr.identifier and (
                el.content[1].attr.identifier:match("story%d+.html")
            or
                el.content[1].attr.identifier == "toc.html"
        )
    )
end

--[[
Given top-level blocks of a Instapaper epub, find the delimiters between stories and split
the blocks into sections for each story.
]]
local function split_into_sections(blocks)
    local section_tables = {}

    local function new_section()
        table.insert(section_tables, {})
    end

    local function append_to_current_section(val)
        table.insert(section_tables[#section_tables], val)
    end

    new_section()

    for _, element in ipairs(blocks) do
        if element_is_insta_section_delimiter(element) then
            new_section()
        else
            append_to_current_section(element)
        end
    end

    -- If we randomly got lucky and found a delimiter
    -- on the first block, we'll have an empty section
    -- at the front of the list
    if #section_tables[1] == 0 then
        table.remove(section_tables, 1)
    end

    return section_tables
end

--[[
Each story in an instapaper epub has an initial heading that's bizarrely level 4.
This is probably a naive attempt at styling, but it screws up the semantics of the
epub from Pandoc's perspective. This function takes the blocks that comprise an
individual section and ensures the first heading in the sequence is an h1 + all
the rest are incremented (as Instapaper blindly passed through any h1s that might
occur in the body of a story).
]]
local function fix_headers_of_section_if_needed(section_blocks)
    local found_first_header = false

    section_blocks = section_blocks
        :walk({
            traverse = 'topdown',
            Header = function(header)
                if not found_first_header then
                    found_first_header = true
                    header.level = 1
                    header.attr = {
                        ['section-heading'] = 'true'
                    }
                    return header
                end
            end
        }):walk({
            Header = function(header)
                if not header.attr.attributes['section-heading'] then
                    header.level = header.level + 1
                end
                return header
            end
        })

    if found_first_header then
        -- Drop everything prior to the first header
        for _, el in ipairs(section_blocks:clone()) do
            if el.t == 'Header' then
                break
            end
            section_blocks:remove(1)
        end
    end

    return section_blocks
end


local function filter_pandoc_normalize_headers(pdoc)
    local accumulating_section = false

    local sections_tables = split_into_sections(pdoc.blocks)
    -- The first section is a cover page we really don't need
    table.remove(sections_tables, 1)
    table.remove(sections_tables, 1)

    local section_list = pandoc.List {}
    for _, section_table in ipairs(sections_tables) do
        section_list:extend(fix_headers_of_section_if_needed(pandoc.Blocks(section_table)))
    end

    pdoc.blocks = pandoc.utils.make_sections(false, 1, section_list)
    return pdoc, false
end

--[[
Instapaper passes through various html elements that (to Kobo eReaders at least)
are not valid in epub files. This just removes any "raw" html elements that pandoc
could not parse.
]]
local function filter_raw_remove_html(raw_block_or_inline)
    if raw_block_or_inline.format == 'html' then
        return pandoc.List {}
    end
end

local function filter_para_delete_control_buttons(para)
    if #para.content > 10 then 
        return nil
    end

    local found_archive_all = false
    local found_download_newest = false

    for _, el in ipairs(para.content) do
        if el.t == 'Link' then
            found_archive_all = found_archive_all or (
                pandoc.utils.stringify(el):match('^Archive.*All$')
                and 
                el.target:match('^http://www.instapaper.com/k%?a=archiveall')
            )
            found_download_newest = found_download_newest or (
                pandoc.utils.stringify(el):match('^Download.*Newest$')
                and 
                el.target:match('^http://www.instapaper.com/k%?a=mobi')
            )
        end
    end

    if found_archive_all and found_download_newest then
        return pandoc.List {}
    end
end

local function filter_image_delete_cover(image)
    if image.src == 'cover-image.jpg' then
        return pandoc.List {}
    end
end

local function filter_clear_header_section_attr(header)
    if header.attr['section-header'] then
        header.attr['section-header'] = nil
    end
end

return {
    {
        Pandoc = filter_pandoc_normalize_headers,
        RawBlock = filter_raw_remove_html,
        RawInline = filter_raw_remove_html
    },
    {
        Para = filter_para_delete_control_buttons,
        Image = filter_image_delete_cover,
        Header = filter_clear_header_section_attr,
    },
}
