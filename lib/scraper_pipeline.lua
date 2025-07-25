require("scraper_types")

local function require_only(path)
    local result = require(path)
    return result
end

--- All of the available scrapers
---@type Scraper[]
local scrapers_by_name = {
    bluesky = require_only("scrapers.bluesky"),
    twitter = require_only("scrapers.twitter"),
    furaffinity = require_only("scrapers.furaffinity"),
    e621 = require_only("scrapers.e621"),
    cohost = require_only("scrapers.cohost"),
    itakuee = require_only("scrapers.itakuee"),
    inkbunny = require_only("scrapers.inkbunny"),
    mastodon = require_only("scrapers.mastodon"),
    -- deviantart = require_only("scrapers.deviantart"),
    weasyl = require_only("scrapers.weasyl"),
    telegram = require_only("scrapers.telegram"),
}
local scrapers = table.values(scrapers_by_name)

---Given a queue entry, make any file reads necessary to convert the data into an archive task for the final stage of the pipeline.
---@param queue_entry ActiveQueueEntry The queue entry to create an archive task for.
---@return PipelineTaskArchive
---@overload fun(model: Model, queue_entry: ActiveQueueEntry): nil, PipelineError
local function make_archive_task_from_help_answer(queue_entry, user_id)
    local task, json_err = DecodeJson(queue_entry.help_answer)
    if not task then
        return nil, PipelineErrorPermanent(json_err)
    end
    if task.discard_all then
        return nil, PipelineErrorDiscard()
    end
    if
        not task
        or type(task) ~= "table"
        or not task.sources
        or not task.subtasks
    then
        return nil,
            PipelineErrorPermanent(
                "The answer to the request for help is missing required data."
            )
    end
    for i = 1, #task.subtasks do
        local subtask = task.subtasks[i]
        if not subtask then
            return nil,
                PipelineErrorPermanent(
                    "The answer to request for help has a corrupt list of scraped site data."
                )
        end
        subtask.media_data = FsTools.load_queue(subtask.media_file, user_id)
        if not subtask.media_data then
            return nil,
                PipelineErrorPermanent(
                    "A downloaded image for this queue entry is missing. Select this entry and choose Try Again."
                )
        end
        for j = 1, #(subtask.thumbnails or {}) do
            local thumbnail = subtask.thumbnails[j]
            if not thumbnail then
                return nil,
                    PipelineErrorPermanent(
                        "The answer to the request for help has a corrupt thumbnail."
                    )
            end
            thumbnail.image_data =
                FsTools.load_queue(thumbnail.image_file, user_id)
            if not thumbnail.image_data then
                return nil,
                    PipelineErrorPermanent(
                        "A thumbnail image for this queue entry is missing. Select this entry and choose Try Again."
                    )
            end
        end
    end
    task.qid = queue_entry.qid
    return task
end

---Given a queue entry, make any other database queries and file reads necessary to convert the data into a task for the rest of the pipeline.
---@param model Model Database connection.
---@param queue_entry ActiveQueueEntry The queue entry to create a scrape task for.
---@return PipelineTask (Either PipelineTaskScrape or PipelineTaskLookUp, depending on what needs to be done)
---@overload fun(model: Model, queue_entry: ActiveQueueEntry): nil, PipelineError
local function make_scrape_task_from_queue_entry(model, queue_entry)
    if queue_entry.link and queue_entry.image then
        return nil,
            PipelineErrorPermanent(
                "Queue items cannot have both a link and an image. Copy/save one or the other and add it to the queue again."
            )
    elseif queue_entry.link then
        ---@type PipelineTaskScrape
        local result = {
            type = PipelineTaskType.Scrape,
            qid = queue_entry.qid,
            sources = { queue_entry.link },
        }
        return result
    elseif queue_entry.image then
        local media_data = FsTools.load_queue(queue_entry.image, model.user_id)
        if not media_data then
            return nil,
                PipelineErrorPermanent(
                    "The file for this queue entry could not be read from disk. It may have been deleted?"
                )
        end
        ---@type PipelineTaskLookUp
        local result = {
            type = PipelineTaskType.LookUp,
            qid = queue_entry.qid,
            image_data = media_data,
            mime_type = queue_entry.image_mime_type,
        }
        return result
    else
        return nil,
            PipelineErrorPermanent(
                "An internal error occurred while trying to create a scraping task for this entry."
            )
    end
end

---"Deserialize" the queue entry from the database and prepare a task.
---If the queue entry has an image, also load it from disk.
---@param model Model the database connection
---@param queue_entry ActiveQueueEntry The queue entry from the database.
---@return PipelineTask
---@overload fun(Model, ActiveQueueEntry): nil, PipelineError
local function p_deserialize(model, queue_entry, _)
    if queue_entry.retry_count > 2 then
        return nil,
            {
                type = PipelineErrorType.RetryLimitReached,
                description = "I tried to scrape this 3 times without succeeding, so I'm giving up.",
            }
    elseif queue_entry.help_ask and queue_entry.help_answer then
        return make_archive_task_from_help_answer(queue_entry, model.user_id)
    elseif queue_entry.help_ask then
        return nil,
            PipelineErrorPermanent(
                "This queue entry got fed back into the scraper system before the request for help was answered, which is a bug."
            )
    elseif
        queue_entry.status == QueueStatus.ToDo
        or (queue_entry.help_ask ~= nil and queue_entry.help_answer ~= nil)
    then
        model:incrementQueueItemRetryCount(queue_entry.qid)
        return make_scrape_task_from_queue_entry(model, queue_entry)
    else
        return nil,
            PipelineErrorPermanent(
                "This queue entry is either already archived or is in an error state, but it has been fed back into the scraper, which is a bug."
            )
    end
end

local function can_process_uri(uri)
    for i = 1, #scrapers do
        if scrapers[i].can_process_uri(uri) then
            return true
        end
    end
    return false
end

---Scrape the sources for the queue entry.
---If this entry is an image, look up sources first using FuzzySearch/Fluffle.xyz
---@param model Model The database connection.
---@param queue_entry ActiveQueueEntry The queue entry from the database.
---@param task PipelineTask The task prepared by the deserialize step.
---@return PipelineTask
---@overload fun(Model, ActiveQueueEntry, PipelineTask): nil, PipelineError
local function p_scrape(model, queue_entry, task)
    if task.type == PipelineTaskType.LookUp then
        ---@cast task PipelineTaskLookUp
        local sources, ris_err = Ris.search(task.image_data, task.mime_type)
        if not sources then
            return nil, PipelineErrorPermanent(ris_err)
        end
        sources[#sources + 1] = queue_entry.tg_source_link
        if #sources > 0 then
            task = {
                type = PipelineTaskType.Scrape,
                qid = task.qid,
                sources = sources,
            }
        else
            return nil,
                PipelineErrorPermanent(
                    "No sources found for this image in the FuzzySearch or Fluffle.xyz databases."
                )
        end
    end
    if task.type ~= PipelineTaskType.Scrape then
        Log(
            kLogDebug,
            "Ignoring %d task; not a %s task (%d)"
                % { task.type, "Scrape", PipelineTaskType.Scrape }
        )
        return task
    end
    ---@type ScrapedSourceData[][]
    local scraped = {}
    ---@type PipelineError[]
    local errors = {}
    for i = 1, #task.sources do
        local source = task.sources[i]
        local processed = false
        for j = 1, #scrapers do
            local scraper = scrapers[j]
            if scraper.can_process_uri(source) then
                scraped[#scraped + 1], errors[#errors + 1] =
                    scraper.process_uri(source)
                processed = true
                break
            end
        end
        if not processed then
            errors[#errors + 1] =
                PipelineErrorPermanent("No scrapers could process " .. source)
        end
    end
    if #scraped > 0 then
        ---@cast task PipelineTaskFetch
        task.type = PipelineTaskType.Fetch
        task.scraped = scraped
        return task
    else
        return nil, PipelineErrorPermanent(EncodeJson(errors))
    end
end

local function log_strip_bin(obj)
    if type(obj) == "table" then
        local result = {}
        if #obj > 0 then
            for i = 1, #obj do
                result[i] = log_strip_bin(obj[i])
            end
        else
            for k, v in pairs(obj) do
                result[k] = log_strip_bin(v)
            end
        end
        return result
    elseif type(obj) == "string" then
        if #obj > 400 then
            return "[data removed to prevent log spam]"
        else
            return obj
        end
    else
        return obj
    end
end

---Fetch the images found by the scraper.
---@param model Model The database connection.
---@param queue_entry ActiveQueueEntry The queue entry from the database.
---@param task PipelineTask The task prepared by the scrape step.
---@return PipelineTask
---@overload fun(Model, ActiveQueueEntry, PipelineTask): nil, PipelineError
local function p_fetch(model, queue_entry, task)
    if task.type ~= PipelineTaskType.Fetch then
        Log(
            kLogDebug,
            "Ignoring %d task; not a %s task (%d)"
                % { task.type, "Fetch", PipelineTaskType.Fetch }
        )
        return task
    end
    ---@cast task PipelineTaskFetch
    for i = 1, #task.scraped do
        local scraped_data_for_source = task.scraped[i]
        for j = 1, #scraped_data_for_source do
            local scraped_data = scraped_data_for_source[j]
            ---@cast scraped_data FetchedSourceData
            assert(
                scraped_data.media_url,
                "media_url was nil in "
                    .. EncodeJson(log_strip_bin(scraped_data))
            )
            local media_data, err_or_headers =
                Nu.FetchMedia(scraped_data.media_url)
            if not media_data then
                return nil, err_or_headers
            end
            local mime_type = err_or_headers["Content-Type"]
                or Nu.guess_mime_from_url(scraped_data.media_url)
                or "image/jpeg"
            scraped_data.media_data = media_data
            if
                mime_type ~= "application/octet-stream"
                or not scraped_data.mime_type
            then
                scraped_data.mime_type = mime_type
            end
            local thumbnails = scraped_data.thumbnails or {}
            for k = 1, #thumbnails do
                local thumbnail = thumbnails[k]
                assert(
                    thumbnail.raw_uri,
                    "thumbnail.raw_uri was nil for index %d in %s"
                        % { k, EncodeJson(log_strip_bin(scraped_data)) }
                )
                local image_data, thumb_err_or_headers =
                    Nu.FetchMedia(thumbnail.raw_uri)
                if not image_data then
                    return nil, thumb_err_or_headers
                end
                local thumb_mime = thumb_err_or_headers["Content-Type"]
                    or Nu.guess_mime_from_url(thumbnail.raw_uri)
                    or "image/jpeg"
                thumbnail.image_data = image_data
                if
                    thumb_mime ~= "application/octet-stream"
                    or not thumbnail.mime_type
                then
                    thumbnail.mime_type = thumb_mime
                end
            end
        end
    end
    local scraped = task.scraped
    task.scraped = nil
    ---@cast task PipelineTaskDecode
    task.type = PipelineTaskType.Decode
    task.fetched = scraped
    return task
end

---@param imageu8 img.Imageu8 The image to thumbnail
---@return Thumbnail
---@overload fun(imageu8: img.Imageu8): nil, string
local function make_thumbnail(imageu8)
    local thumbnail, thumb_err = imageu8:resize(192)
    if not thumbnail then
        return nil, thumb_err
    end
    local thumbnail_data, td_err = thumbnail:savebufferwebp(75.0)
    if not thumbnail_data then
        return nil, td_err
    end
    ---@type Thumbnail
    local result = {
        image_data = thumbnail_data,
        mime_type = "image/webp",
        width = thumbnail:width(),
        height = thumbnail:height(),
        scale = 1,
    }
    return result
end

---@param model Model The database connection.
---@param sources string[] A list of URLs to look for in the sources table.
---@param hash integer? The gradient hash of the image, if available.
---@return DuplicateData[]
---@overload fun(model: Model, sources: string[], hash: integer?): nil, string
local function check_for_duplicates(model, sources, hash)
    ---@type DuplicateData[]
    local duplicates_by_image_id = {}
    local source_dupes, sd_err = model:checkDuplicateSources(sources)
    if not source_dupes then
        return nil, sd_err
    end
    for dupe_url, dupe_image_ids in pairs(source_dupes) do
        for i = 1, #dupe_image_ids do
            local dupe_image_id = dupe_image_ids[i]
            if not duplicates_by_image_id[dupe_image_id] then
                duplicates_by_image_id[dupe_image_id] = {
                    duplicate_of = dupe_image_id,
                    matched_sources = {},
                }
            end
            local dst = duplicates_by_image_id[dupe_image_id].matched_sources
            dst[#dst + 1] = dupe_url
        end
    end
    if hash then
        local similar, s_err = model:findSimilarImageHashes(hash, 3)
        if not similar then
            return nil, s_err
        end
        for s_idx = 1, #similar do
            local similar_record = similar[s_idx]
            if not duplicates_by_image_id[similar_record.image_id] then
                duplicates_by_image_id[similar_record.image_id] = {
                    duplicate_of = similar_record.image_id,
                    matched_sources = {},
                }
            end
            duplicates_by_image_id[similar_record.image_id].similarity = (
                (64 - similar_record.distance)
                / 64
                * 100
            )
        end
    end
    local result = {}
    for _, duplicate_data in pairs(duplicates_by_image_id) do
        result[#result + 1] = duplicate_data
    end
    table.sort(result, function(a, b)
        return (a.similarity or 0) > (b.similarity or 0)
    end)
    return result
end

---Decode all the images found by the scraper, compute thumbnails, and check for duplicates.
---@param model Model The database connection.
---@param queue_entry ActiveQueueEntry The queue entry from the database.
---@param task PipelineTask The task prepared by the fetch step.
---@return PipelineTask
---@overload fun(Model, ActiveQueueEntry, PipelineTask): nil, PipelineError
local function p_decode(model, queue_entry, task)
    if task.type ~= PipelineTaskType.Decode then
        Log(
            kLogDebug,
            "Ignoring %d task; not a %s task (%d)"
                % { task.type, "Decode", PipelineTaskType.Decode }
        )
        return task
    end
    ---@cast task PipelineTaskDecode
    local any_duplicates = false
    for i = 1, #task.fetched do
        local scraped_data_for_source = task.fetched[i]
        for j = 1, #scraped_data_for_source do
            local scraped_data = scraped_data_for_source[j]
            ---@cast scraped_data DecodedSourceData
            local hash = nil
            -- Skip all of this if the image library is not available in this Redbean,
            -- or if the scraped data is not for an image.
            if img and scraped_data.kind == DbUtil.k.ImageKind.Image then
                -- Load the image
                local imageu8, img_err = img.loadbuffer(scraped_data.media_data)
                if not imageu8 then
                    Log(
                        kLogInfo,
                        "Failed to decode the image: %s" % { img_err }
                    )
                else
                    scraped_data.width = imageu8:width()
                    scraped_data.height = imageu8:height()
                    -- Make a thumbnail
                    local thumbnail, thumb_err = make_thumbnail(imageu8)
                    if not thumbnail then
                        Log(
                            kLogInfo,
                            "Failed to make thumbnail for image, will bypass: %s"
                                % { thumb_err }
                        )
                    else
                        if not scraped_data.thumbnails then
                            scraped_data.thumbnails = {}
                        end
                        scraped_data.thumbnails[#scraped_data.thumbnails + 1] =
                            thumbnail
                    end
                    -- Compute the gradient hash
                    hash = imageu8:gradienthash()
                    scraped_data.hash = hash
                end
            end
            -- Check for duplicates
            local sources = table.pack(
                scraped_data.this_source,
                table.unpack(scraped_data.additional_sources or {})
            )
            local duplicates, dupe_err =
                check_for_duplicates(model, sources, hash)
            if not duplicates then
                return nil, PipelineErrorPermanent(dupe_err)
            end
            Log(kLogInfo, "Found duplicates: " .. EncodeJson(duplicates))
            scraped_data.duplicates = duplicates
            if #duplicates > 0 then
                any_duplicates = true
            end
        end
    end
    local fetched = task.fetched
    task.fetched = nil
    ---@cast task PipelineTaskDecide
    task.type = PipelineTaskType.Decide
    task.decoded = fetched
    task.any_duplicates = any_duplicates
    return task
end

---Decide what to do with the data produced by the scraper and decoder.
---This step will either produce:
---  * an Archive task with one or more subtasks that instruct the pipeline to either save a new record or merge new data into an existing record, or
---  * an AskHelp task requesting the user's input on what should be done.
---@param model Model The database connection.
---@param queue_entry ActiveQueueEntry The queue entry from the database.
---@param task PipelineTask The task prepared by the scrape step.
---@return PipelineTask
---@overload fun(Model, ActiveQueueEntry, PipelineTask): nil, PipelineError
local function p_decide(model, queue_entry, task)
    if task.type ~= PipelineTaskType.Decide then
        Log(
            kLogDebug,
            "Ignoring %d task; not a %s task (%d)"
                % { task.type, "Decide", PipelineTaskType.Decide }
        )
        return task
    end
    ---@cast task PipelineTaskDecide
    local data = task.decoded
    -- Case 1: There are duplicates. Ask for help.
    if task.any_duplicates then
        return {
            type = PipelineTaskType.AskHelp,
            qid = task.qid,
            decoded = data,
            sources = task.sources,
            any_duplicates = true,
        }
    end
    -- Case 2: There's only one source. Save all of the media from that source.
    if #data == 1 then
        local archive_subtasks = table.map(data[1], function(item)
            ---@cast item PipelineSubtaskArchive
            item.archive = true
            return item
        end)
        return {
            type = PipelineTaskType.Archive,
            qid = task.qid,
            subtasks = archive_subtasks,
            sources = task.sources,
        }
    end
    -- Case 3: All of the sources only have one media file.  Pick the largest
    -- media file of the bunch.
    local max_results = math.max(table.unpack(table.map(data, function(item)
        return #item
    end)))
    if max_results == 1 then
        local largest_source = table.reduce(
            table.flatten(data),
            nil,
            ---@param acc ScrapedSourceData?
            ---@param next ScrapedSourceData
            ---@return ScrapedSourceData
            function(acc, next)
                if acc == nil then
                    return next
                end
                if next.width > acc.width and next.height > acc.height then
                    return next
                else
                    return acc
                end
            end
        )
        assert(
            largest_source ~= nil,
            "largest_source was nil, which should only happen when the list of sources was empty, but that should be impossible here."
        )
        ---@cast largest_source PipelineSubtaskArchive
        largest_source.archive = true
        return {
            type = PipelineTaskType.Archive,
            qid = task.qid,
            subtasks = { largest_source },
            sources = task.sources,
        }
    end
    -- Case N: No heuristics, ask the user for help.
    return {
        type = PipelineTaskType.AskHelp,
        qid = task.qid,
        decoded = data,
        sources = task.sources,
    }
end

---Either archive a new record or replace the media file for an existing one.
---@param model Model Database connection.
---@param subtask PipelineSubtask
---@return integer
local function do_archive_subtask_insert_update_image(model, subtask)
    local image, image_err = nil, nil
    if subtask.archive then
        image, image_err = model:insertImage(
            subtask.media_data,
            subtask.mime_type,
            subtask.width,
            subtask.height,
            subtask.kind,
            subtask.rating
        )
    elseif subtask.merge then
        ---@cast subtask PipelineSubtaskMerge
        image, image_err = model:replaceImage(
            subtask.merge,
            subtask.media_data,
            subtask.mime_type,
            subtask.width,
            subtask.height
        )
    else
        error("Invalid subtask type (not merge or archive)")
    end
    if not image then
        Log(
            kLogInfo,
            "Error inserting/updating image in database: " .. image_err
        )
        error(image_err)
    end
    Log(
        kLogVerbose,
        "Inserted/updated image record in(to) database (result: %s)"
            % { EncodeJson(image) }
    )
    return image.image_id
end

---Insert sources for a record.
---@param model Model Database connection.
---@param image_id integer ID of the record to associate sources with.
---@param sources string[] List of URLs to associate with the record as sources.
local function do_archive_subtask_insert_sources(model, image_id, sources)
    Log(kLogInfo, "Sources (deduped): " .. EncodeJson(sources))
    local source_ok, source_err = model:insertSourcesForImage(image_id, sources)
    if not source_ok then
        Log(kLogInfo, "Error inserting sources into database: " .. source_err)
        error(source_err)
    end
end

---Create an artist and link it with a record, or add a new artist and link it.
---@param model Model Database connection.
---@param image_id integer ID of the record to associate artists with.
---@param subtask PipelineSubtask The subtask containing author information.
local function do_archive_subtask_insert_authors(model, image_id, subtask)
    for j = 1, #subtask.authors do
        local author = subtask.authors[j]
        local artist_ok, artist_err = model:createOrAssociateArtistWithImage(
            image_id,
            subtask.canonical_domain,
            author
        )
        if not artist_ok then
            Log(kLogInfo, "Unable to link artist with record: " .. artist_err)
            error(artist_err)
        end
    end
end

---Insert tags for a record.
---@param model Model Database connection.
---@param image_id integer ID of the record to insert tags for.
---@param subtask PipelineSubtask The subtask containing tag information.
local function do_archive_subtask_insert_tags(model, image_id, subtask)
    if subtask.incoming_tags then
        local add_tags_ok, add_tags_err = model:addIncomingTagsForImage(
            image_id,
            subtask.canonical_domain,
            subtask.incoming_tags
        )
        if not add_tags_ok then
            Log(kLogInfo, "Error adding tags: " .. tostring(add_tags_err))
            error(add_tags_err)
        end
    end
end

---Add the record to a group (if necessary).
---@param model Model Database connection.
---@param image_id integer ID of the record to add to the group.
---@param ig_id integer? ID of the group to add the record to.
local function do_archive_subtask_add_to_group(model, image_id, ig_id)
    if ig_id then
        local gl_ok, gl_err = model:addImageToGroupAtEnd(image_id, ig_id)
        if not gl_ok then
            Log(kLogInfo, "Unable to link group with record: " .. gl_err)
            error(gl_err)
        end
    end
end

---Add thumbnails for a record.
---@param model Model Database connection.
---@param image_id integer ID of the record to associate the thumbnails with.
---@param subtask PipelineSubtask The subtask containing thumbnail information.
local function do_archive_subtask_add_thumbnails(model, image_id, subtask)
    if subtask.thumbnails then
        for i = 1, #subtask.thumbnails do
            local thumbnail = subtask.thumbnails[i]
            local t_ok, t_err = model:insertThumbnailForImage(
                image_id,
                thumbnail.image_data,
                thumbnail.width,
                thumbnail.height,
                thumbnail.scale,
                thumbnail.mime_type
            )
            if not t_ok then
                error(t_err)
            end
        end
    end
end

---Insert the gradient hash for an image.
---@param model Model Database connection.
---@param image_id integer ID of the record to insert the hash for.
---@param hash integer The gradient hash of the image.
local function do_archive_subtask_insert_hash(model, image_id, hash)
    if hash then
        local h_ok, h_err = model:insertImageHash(image_id, hash)
        if not h_ok then
            error(h_err)
        end
    end
end

local function normalize_uri(uri)
    local norm_uri = uri
    for i = 1, #scrapers do
        Log(kLogDebug, "normalizing with " .. tostring(i))
        norm_uri = scrapers[i].normalize_uri(norm_uri)
        Log(kLogDebug, "url is now " .. norm_uri)
    end
    return norm_uri
end

---Do all the work necessary to archive one subtask.
---@param model Model Database connection.
---@param subtask PipelineSubtask The subtask to archive.
---@param sources string[] A list of all of the source URLs that were found for the parent task.
---@param ig_id integer? ID of a group to add the new (or existing) record to, or nil if it should not be added to a group.
local function do_archive_subtask(model, subtask, sources, ig_id)
    local sources_with_dupes = {
        subtask.this_source,
    }
    table.extend(sources_with_dupes, sources)
    table.extend(sources_with_dupes, subtask.additional_sources)
    -- There may be duplicates in this list, but the database query ignores duplicates on insert.
    local this_item_sources = table.map(sources_with_dupes, normalize_uri)

    local image_id = do_archive_subtask_insert_update_image(model, subtask)
    do_archive_subtask_insert_sources(model, image_id, this_item_sources)
    do_archive_subtask_insert_authors(model, image_id, subtask)
    do_archive_subtask_insert_tags(model, image_id, subtask)
    do_archive_subtask_add_to_group(model, image_id, ig_id)
    do_archive_subtask_add_thumbnails(model, image_id, subtask)
    if subtask.archive then
        do_archive_subtask_insert_hash(model, image_id, subtask.hash)
    end
end

---Archive one or more pieces of media.
---@param model Model The database connection.
---@param task PipelineTaskArchive The task prepared by the scrape step.
---@return PipelineTask
---@overload fun(Model, ActiveQueueEntry, PipelineTask): nil, PipelineError
local function do_archive(model, task)
    local subtasks = task.subtasks
    assert(subtasks, "subtasks was nil, task is " .. EncodeJson(task))
    local group = nil
    Log(kLogInfo, "#subtasks: %d" % { #subtasks })
    -- Count the number of subtasks where st.archive is non-nil, so that we can
    -- avoid making a group that only actually has one record in it.  This can
    -- occur when the scraper processes a Bluesky link with four images, the
    -- first three of which have already been archived from elsewhere (FA), but
    -- the fourth one is new.
    local archive_subtask_count = table.reduce(
        table.map(subtasks, function(st)
            return st.archive
        end),
        0,
        function(acc, next)
            return next and acc + 1 or acc
        end
    )
    if archive_subtask_count > 1 then
        local name = "Untitled group by "
            .. table.reduce(subtasks[1].authors, nil, function(acc, next)
                if acc == nil then
                    return next.display_name
                else
                    return acc .. ", " .. next.display_name
                end
            end)
        local group_err
        group, group_err = model:createImageGroup(name)
        if not group then
            Log(kLogInfo, "Unable to make group: " .. group_err)
            error(group_err)
        end
    end
    for i = 1, #subtasks do
        do_archive_subtask(
            model,
            subtasks[i],
            task.sources,
            group and group.ig_id or nil
        )
    end
    local q_ok, q_err = model:setQueueItemStatusAndDescription(
        task.qid,
        QueueStatus.Archived,
        ""
    )
    if not q_ok then
        error(
            "Unable to mark the now-completed queue entry as complete: "
                .. q_err
        )
    end
    return {}
end

---Serialize the task to JSON and add it to the queue record as a help request.
---This function also saves any images/videos/etc. to disk so that the serialized data isn't enormous.
---@param model Model The database connection.
---@param queue_entry ActiveQueueEntry The queue entry from the database.
---@param task PipelineTaskAskHelp The task prepared by the scrape step.
---@return PipelineTask
---@overload fun(Model, ActiveQueueEntry, PipelineTask): nil, PipelineError
local function do_ask_help(model, queue_entry, task)
    for i = 1, #task.decoded do
        local source_list = task.decoded[i]
        for j = 1, #source_list do
            local scraped_data = source_list[j]
            local filename, f_err = FsTools.save_queue(
                scraped_data.media_data,
                scraped_data.mime_type,
                model.user_id
            )
            if not filename then
                return nil,
                    PipelineErrorPermanent(
                        "Unable to save scraped image file: " .. f_err
                    )
            end
            ---@cast scraped_data table
            scraped_data.media_file = filename
            scraped_data.media_data = nil
            for k = 1, #scraped_data.thumbnails or {} do
                local thumbnail = scraped_data.thumbnails[k]
                local thumb_file, tf_err = FsTools.save_queue(
                    thumbnail.image_data,
                    thumbnail.mime_type,
                    model.user_id
                )
                if not thumb_file then
                    return nil,
                        PipelineErrorPermanent(
                            "Unable to save scraped thumbnail file: " .. tf_err
                        )
                end
                thumbnail.image_file = thumb_file
                thumbnail.image_data = nil
            end
        end
    end
    local qid = task.qid
    task.qid = nil
    local ok, err = model:setQueueItemHelpAsk(qid, task)
    if not ok then
        return nil, PipelineErrorTemporary(err)
    end
    if queue_entry.tg_message_id then
        Bot.update_queue_message_with_status(
            queue_entry.tg_chat_id,
            queue_entry.tg_message_id,
            "I need help to figure this one out: https://werehouse.s0ph0s.dog/queue/%d/help"
                % { queue_entry.qid }
        )
    end

    return {}
end

---Executes the Archive or AskHelp tasks.
---@param model Model The database connection.
---@param queue_entry ActiveQueueEntry The queue entry from the database.
---@param task PipelineTask The task prepared by the decide step.
---@return PipelineTask
---@overload fun(Model, ActiveQueueEntry, PipelineTask): nil, PipelineError
local function p_execute(model, queue_entry, task)
    if task.type == PipelineTaskType.Archive then
        ---@cast task PipelineTaskArchive
        assert(task.subtasks, "subtasks was nil but task type is archive??")
        local SP = "archiving_from_queue"
        model:create_savepoint(SP)
        local ok, result = pcall(do_archive, model, task)
        if not ok then
            model:rollback(SP)
            return nil, PipelineErrorPermanent(result)
        end
        model:release_savepoint(SP)
        if queue_entry.tg_message_id then
            Bot.update_queue_message_with_status(
                queue_entry.tg_chat_id,
                queue_entry.tg_message_id,
                "Archived!"
            )
        end
        return result
    elseif task.type == PipelineTaskType.AskHelp then
        return do_ask_help(model, queue_entry, task)
    else
        Log(
            kLogDebug,
            "Ignoring %d task; not a %s task (%d)"
                % { task.type, "archive/askhelp", PipelineTaskType.Archive }
        )
        return task
    end
end

local function queue_entry_tostr(queue_entry)
    local result = {}
    for key, value in pairs(queue_entry) do
        if type(value) == "string" and #value > 100 then
            local prefix = value:sub(1, 25)
            local suffix = value:sub(#value - 25)
            value = VisualizeControlCodes(
                "%s[elided to prevent log spam]%s" % { prefix, suffix }
            )
        end
        result[key] = value
    end
    return EncodeJson(result)
end

--- Decode a (possibly) JSON error description and present it nicely as a bulleted list.
---@param errdesc string Maybe JSON string describing errors
---@return string # Nicely formatted representation of a JSON error, or the input string if it was not JSON.
local function decode_errors(errdesc)
    local json = DecodeJson(errdesc)
    if not json or #json < 1 then
        return errdesc
    else
        ---@cast json table
        return table.reduce(
            table.map(
                table.filter(json, function(item)
                    return type(item) == "table"
                end),
                function(item)
                    return item.description
                end
            ),
            "",
            function(acc, next)
                return acc .. "\n" .. next
            end
        ) or "unable to process error message"
    end
end

---Update a queue entry with status/error information when one occurs.
---@param model Model
---@param queue_entry ActiveQueueEntry
---@param error PipelineError
local function handle_queue_error(model, queue_entry, error)
    Log(kLogDebug, "error to be handled: %s" % { EncodeJson(error) })
    local status_result, errmsg2 = model:setQueueItemStatusAndDescription(
        queue_entry.qid,
        error.type,
        error.description
    )
    if not status_result then
        Log(kLogWarn, "While processing queue for user %d, item %d: %s" % {
            model.user_id,
            queue_entry.qid,
            errmsg2,
        })
    end
    if queue_entry.tg_message_id then
        local msg = decode_errors(error.description)
        Bot.update_queue_message_with_status(
            queue_entry.tg_chat_id,
            queue_entry.tg_message_id,
            "Error: " .. msg
        )
    end
end

---@type PipelineFunction[]
local entry_pipeline = {
    p_deserialize,
    p_scrape,
    p_fetch,
    p_decode,
    p_decide,
    p_execute,
}

---Process one queue entry.
---@param model Model Database connection.
---@param queue_entry ActiveQueueEntry The queue entry to process.
local function process_entry(model, queue_entry)
    Log(
        kLogInfo,
        "Processing queue entry %s" % { queue_entry_tostr(queue_entry) }
    )
    local task, step_err = nil, nil
    for i = 1, #entry_pipeline do
        Log(kLogVerbose, "Process entry pipeline step %d" % { i })
        local step = entry_pipeline[i]
        task, step_err = step(model, queue_entry, task)
        if not task then
            handle_queue_error(model, queue_entry, step_err)
            return
        end
    end
end

---Process the queue for one user.
---@param model Model Database connection.
---@param queue_records ActiveQueueEntry[] The collection of queue records for that one user.
local function process_queue(model, queue_records)
    for _, queue_entry in ipairs(queue_records) do
        process_entry(model, queue_entry)
    end
end

---Process the queue for every user.
local function process_all_queues()
    local user_ids, errmsg = Accounts:getAllUserIds()
    if not user_ids then
        Log(kLogWarn, errmsg)
        return
    end
    Log(kLogInfo, "Beginning queue processing.")
    for _, user_id in ipairs(user_ids) do
        user_id = user_id.user_id
        Log(kLogInfo, "Beginning queue processing for user %s" % { user_id })
        ---@type Model
        local model = DbUtil.Model:new(nil, user_id)
        local queue_records, errmsg2 = model:getAllActiveQueueEntries()
        if queue_records then
            Log(
                kLogInfo,
                "Processing %d queue entries for %s"
                    % { #queue_records, user_id }
            )
            -- Use pcall to isolate each user's queue processing. That way, if
            -- one user has something in their queue that causes a problem, it
            -- doesn't mean that everyone after them gets blocked too.
            local q_ok, q_err =
                xpcall(process_queue, debug.traceback, model, queue_records)
            if not q_ok then
                Log(
                    kLogWarn,
                    "Error occurred while processing queue for user %s: %s"
                        % { user_id, q_err }
                )
            end
        else
            Log(kLogWarn, errmsg2)
        end
        Log(
            kLogInfo,
            "Finished processing queue entries for user %s" % { user_id }
        )
        model.conn:close()
    end
    Log(kLogInfo, "Ending queue processing.")
end

return {
    process_all_queues = process_all_queues,
    process_entry = process_entry,
    scraper = scrapers_by_name,
    can_process_uri = can_process_uri,
    normalize_uri = normalize_uri,
    CANONICAL_DOMAINS_WITH_TAGS = {
        "www.furaffinity.net",
        "e621.net",
        "cohost.org",
        "itaku.ee",
        "www.deviantart.com",
        "www.weasyl.com",
        "inkbunny.net",
    },
}
