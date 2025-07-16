#ifndef ZUPGRADE_PATH
#error "ZUPGRADE_PATH must be defined"
#endif

#include <Windows.h>
#include <stdio.h>
#include <stdlib.h>

#undef EXIT_FAILURE
#define EXIT_FAILURE 255

char *read_zig_version()
{
	FILE *zig_version_fd = fopen(ZUPGRADE_PATH "\\zig\\selected", "r");
	if (!zig_version_fd)
	{
		fprintf(stderr, "Cannot open " ZUPGRADE_PATH "\\zig\\selected");
		exit(EXIT_FAILURE);
	}

	fseek(zig_version_fd, 0, SEEK_END);
	size_t file_size = ftell(zig_version_fd);
	fseek(zig_version_fd, 0, SEEK_SET);

	char *zig_version = malloc(file_size + 1);
	if (!zig_version)
	{
		fprintf(stderr, "Memory allocation failed");
		exit(EXIT_FAILURE);
	}

	if (fread(zig_version, 1, file_size, zig_version_fd) != file_size)
	{
		fprintf(stderr, "File read failed");
		exit(EXIT_FAILURE);
	}

	zig_version[file_size] = '\0';
	fclose(zig_version_fd);

	if (strlen(zig_version) == 0)
	{
		fprintf(stderr, "You need to select a zig version");
		exit(EXIT_FAILURE);
	}

	return zig_version;
}

int main(int argc, char **argv)
{
	char *zig_version = read_zig_version();
	char *zig_exe_path = malloc(sizeof(ZUPGRADE_PATH "\\zig\\") + strlen(zig_version) + sizeof("\\zig.exe"));
	if (!zig_exe_path)
	{
		fprintf(stderr, "Memory allocation failed");
		return EXIT_FAILURE;
	}

	strcpy(zig_exe_path, ZUPGRADE_PATH "\\zig\\");
	strcat(zig_exe_path, zig_version);
	strcat(zig_exe_path, "\\zig.exe");
	free(zig_version);

	size_t cmdline_len = strlen(zig_exe_path);

	for (size_t i = 0; i < argc; i++)
		cmdline_len += strlen(argv[i]) + 1; // The plus one is for a space

	char *cmdline = malloc(cmdline_len);
	if (!cmdline)
	{
		fprintf(stderr, "Memory allocation failed");
		return EXIT_FAILURE;
	}

	char *str = cmdline;
	strcpy(str, zig_exe_path);
	str += strlen(zig_exe_path);

	for (size_t i = 1; i < argc; i++)
	{
		*str++ = ' ';
		strcpy(str, argv[i]);
		str += strlen(argv[i]);
	}
	*str = '\0';

	STARTUPINFO si;
	PROCESS_INFORMATION pi;

	memset(&si, 0, sizeof(STARTUPINFO));
	memset(&pi, 0, sizeof(PROCESS_INFORMATION));

	si.cb = sizeof(STARTUPINFO);

	if (!CreateProcess(zig_exe_path, cmdline, NULL, NULL, FALSE, 0, NULL, NULL, &si, &pi))
	{
		fprintf(stderr, "Failed to launch %s\n", cmdline);
		free(cmdline);
		return EXIT_FAILURE;
	}

	free(cmdline);

	WaitForSingleObject(pi.hProcess, INFINITE);

	DWORD exit_code = EXIT_FAILURE;
	GetExitCodeProcess(pi.hProcess, &exit_code);

	CloseHandle(pi.hProcess);
	CloseHandle(pi.hThread);

	return (int)exit_code;
}
