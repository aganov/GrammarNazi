#include "Inference.h"
#include "llama.h"
#include "chat.h"
#include "common.h"
#include "sampling.h"
#include "log.h"
#include <chrono>
#include <cmath>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <mutex>
#include <stdexcept>

using Clock = std::chrono::steady_clock;
struct Cancelled {};
struct Operation {
    gn_cancel_check cancelled;
    void * user;
    Clock::time_point deadline;
    bool stopped() const { return (cancelled && cancelled(user)) || Clock::now() >= deadline; }
    void check() const {
        if (cancelled && cancelled(user)) throw Cancelled{};
        if (Clock::now() >= deadline) throw std::runtime_error("Local inference timed out. Try a shorter passage.");
    }
};
struct gn_session {
    std::unique_ptr<llama_model, decltype(&llama_model_free)> model{nullptr, llama_model_free};
    common_chat_templates_ptr templates;
    std::string path;
    size_t loads = 0;
    std::mutex mutex;
};
static std::once_flag backend;
static char * copy(const std::string & value) {
    auto * result = static_cast<char *>(std::malloc(value.size() + 1));
    if (!result) throw std::bad_alloc();
    std::memcpy(result, value.c_str(), value.size() + 1);
    return result;
}
extern "C" gn_session * gn_session_create() {
    try {
        std::call_once(backend, [] {
            // Never log prompts, generated text or token dumps.
            llama_log_set([](ggml_log_level, const char *, void *) {}, nullptr);
            common_log_set_verbosity_thold(-1);
            common_log_pause(common_log_main());
            llama_backend_init();
        });
        return new gn_session();
    } catch (...) { return nullptr; }
}
extern "C" void gn_session_destroy(gn_session * session) { delete session; }
extern "C" size_t gn_session_load_count(const gn_session * session) { return session->loads; }
extern "C" void gn_string_free(char * string) { std::free(string); }

static std::string generate(gn_session & session, const char * path, const char * request, Operation & op) {
    op.check();
    if (std::strlen(request) > 256000) throw std::runtime_error("Invalid inference request.");
    const auto body = common_json::parse(request);
    if (!body.is_object() || !body.contains("messages")) throw std::runtime_error("Invalid inference request.");
    const int limit = body.value("max_tokens", 4096);
    const float temperature = body.value("temperature", 0.1f);
    if (limit < 1 || limit > 4096 || !std::isfinite(temperature) || temperature < 0 || temperature > 2)
        throw std::runtime_error("Invalid inference limits.");
    if (!session.model || !session.templates || session.path != path) {
        session.templates.reset(); session.model.reset(); session.path.clear();
        auto params = llama_model_default_params();
        params.n_gpu_layers = 99;
        params.progress_callback = [](float, void * data) { return !static_cast<Operation *>(data)->stopped(); };
        params.progress_callback_user_data = &op;
        session.model.reset(llama_model_load_from_file(path, params));
        op.check();
        if (!session.model) throw std::runtime_error("Could not load the GGUF model. Check the model path and available memory.");
        session.path = path;
        session.loads++;
        session.templates = common_chat_templates_init(session.model.get(), "");
    }
    op.check();
    // A fresh context and sampler prevent text/history leaking between requests.
    op.deadline = Clock::now() + std::chrono::seconds(120);
    auto params = llama_context_default_params();
    params.n_ctx = 16384;
    params.n_batch = 512;
    params.n_ubatch = 128;
    params.n_seq_max = 1;
    params.abort_callback = [](void * data) { return static_cast<Operation *>(data)->stopped(); };
    params.abort_callback_data = &op;
    std::unique_ptr<llama_context, decltype(&llama_free)> ctx(llama_init_from_model(session.model.get(), params), llama_free);
    op.check();
    if (!ctx) throw std::runtime_error("Could not allocate model context. Check available memory.");
    common_chat_templates_inputs inputs;
    inputs.messages = common_chat_msgs_parse_oaicompat(body.at("messages"));
    inputs.reasoning_format = COMMON_REASONING_FORMAT_DEEPSEEK;
    inputs.enable_thinking = false;
    inputs.chat_template_kwargs["enable_thinking"] = "false";
    if (body.contains("response_format")) inputs.json_schema = body.at("response_format").at("schema").dump();
    const auto chat = common_chat_templates_apply(session.templates.get(), inputs);
    auto tokens = common_tokenize(ctx.get(), chat.prompt, true, true);
    if (tokens.empty() || tokens.size() + limit > llama_n_ctx(ctx.get()))
        throw std::runtime_error("The passage exceeds the model context limit. Try a shorter passage.");
    common_params_sampling sampling;
    sampling.temp = temperature;
    if (!chat.grammar.empty()) sampling.grammar = {COMMON_GRAMMAR_TYPE_OUTPUT_FORMAT, chat.grammar};
    sampling.grammar_lazy = chat.grammar_lazy;
    sampling.grammar_triggers = chat.grammar_triggers;
    sampling.generation_prompt = chat.generation_prompt;
    for (const auto & piece : chat.preserved_tokens) {
        const auto ids = common_tokenize(ctx.get(), piece, false, true);
        if (ids.size() == 1) sampling.preserved_tokens.insert(ids.front());
    }
    common_sampler_ptr sampler(common_sampler_init(session.model.get(), sampling));
    if (!sampler) throw std::runtime_error("Could not initialize model sampling.");
    auto decode = [&](llama_token * data, int count) {
        op.check();
        const int status = llama_decode(ctx.get(), llama_batch_get_one(data, count));
        op.check();
        if (status != 0) throw std::runtime_error("Local model inference failed. Please try again.");
    };
    for (size_t offset = 0; offset < tokens.size(); offset += 512) {
        decode(tokens.data() + offset, static_cast<int>(std::min(size_t(512), tokens.size() - offset)));
    }
    const auto * vocab = llama_model_get_vocab(session.model.get());
    std::string text;
    bool stopped = false;
    for (int i = 0; i < limit; ++i) {
        op.check();
        auto token = common_sampler_sample(sampler.get(), ctx.get(), -1);
        common_sampler_accept(sampler.get(), token, true);
        if (llama_vocab_is_eog(vocab, token)) { stopped = true; break; }
        text += common_token_to_piece(ctx.get(), token, true);
        if (text.size() > 2 * 1024 * 1024) throw std::runtime_error("Local model response is too large.");
        for (const auto & stop : chat.additional_stops) {
            if (!stop.empty() && text.size() >= stop.size() && text.compare(text.size() - stop.size(), stop.size(), stop) == 0) {
                text.resize(text.size() - stop.size()); stopped = true; break;
            }
        }
        if (stopped) break;
        if (i + 1 < limit) decode(&token, 1);
    }
    op.check();
    common_chat_parser_params parser(chat);
    parser.reasoning_format = COMMON_REASONING_FORMAT_DEEPSEEK;
    parser.parse_tool_calls = false;
    if (!chat.parser.empty()) parser.parser.load(chat.parser);
    const auto message = common_chat_parse(text, !stopped, parser);
    common_json result = common_json::object();
    common_json choice = common_json::object();
    choice["finish_reason"] = stopped ? "stop" : "length";
    choice["message"] = common_json{{"content", message.content}};
    result["choices"] = common_json::array({choice});
    return result.dump();
}
extern "C" int gn_session_run(gn_session * session, const char * model_path, const char * request,
                                gn_cancel_check cancelled, void * user, char ** output, char ** error) {
    *output = nullptr; *error = nullptr;
    try {
        if (!session || !model_path || !request) throw std::runtime_error("Invalid inference session.");
        std::unique_lock<std::mutex> lock(session->mutex, std::try_to_lock);
        if (!lock.owns_lock()) throw std::runtime_error("Inference is already running.");
        Operation op{cancelled, user, Clock::now() + std::chrono::seconds(90)};
        *output = copy(generate(*session, model_path, request, op));
        return 0;
    } catch (const Cancelled &) { return 2; }
    catch (const common_json_error &) { try { *error = copy("Invalid model request or response."); } catch (...) {} }
    catch (const std::exception & e) { try { *error = copy(e.what()); } catch (...) {} }
    catch (...) { try { *error = copy("Local inference failed."); } catch (...) {} }
    return 1;
}
