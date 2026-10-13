#include <poll.h>
#include <unistd.h>

#include <cstdlib>
#include <deque>

namespace {

std::deque<unsigned char> input_queue;
bool initialized = false;
unsigned int empty_poll_count = 0;

void initialize_script()
{
    initialized = true;

    const char *commands = std::getenv("JYD_CONSOLE_CMDS");
    if (commands == nullptr)
    {
        return;
    }

    for (const char *p = commands; *p != '\0'; ++p)
    {
        if (*p == ';')
        {
            input_queue.push_back('\n');
        }
        else if (*p == '\\' && p[1] != '\0')
        {
            ++p;
            switch (*p)
            {
            case 'n': input_queue.push_back('\n'); break;
            case 'r': input_queue.push_back('\r'); break;
            case 't': input_queue.push_back('\t'); break;
            default:  input_queue.push_back(static_cast<unsigned char>(*p)); break;
            }
        }
        else
        {
            input_queue.push_back(static_cast<unsigned char>(*p));
        }
    }

    if (!input_queue.empty() && input_queue.back() != '\n' &&
        input_queue.back() != '\r')
    {
        input_queue.push_back('\n');
    }
}

void poll_stdin()
{
    struct pollfd fd = {STDIN_FILENO, POLLIN, 0};
    unsigned char buffer[128];

    if (poll(&fd, 1, 0) <= 0 || (fd.revents & POLLIN) == 0)
    {
        return;
    }

    const ssize_t count = read(STDIN_FILENO, buffer, sizeof(buffer));
    for (ssize_t index = 0; index < count; ++index)
    {
        input_queue.push_back(buffer[index]);
    }
}

} // namespace

extern "C" int sim_console_getchar()
{
    if (!initialized)
    {
        initialize_script();
    }

    if (input_queue.empty())
    {
        // Avoid a host system call on every simulated clock while MSH polls.
        if (++empty_poll_count >= 4096)
        {
            empty_poll_count = 0;
            poll_stdin();
        }
    }

    if (input_queue.empty())
    {
        return -1;
    }

    const int ch = input_queue.front();
    input_queue.pop_front();
    return ch;
}
